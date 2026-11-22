-- Role-based staff access, explicit case assignment and attributable casework.

alter table comforce.staff
  add column user_id uuid,
  add column display_name text,
  add column role text not null default 'caseworker',
  add constraint staff_role_check check (role in ('administrator','caseworker')),
  add constraint staff_display_name_check check (
    display_name is null or length(btrim(display_name)) between 1 and 80
  );

-- Existing allowlisted staff are promoted so this migration cannot lock the organization
-- out of the unassigned queue. New staff default to the least-privileged caseworker role.
update comforce.staff
set display_name = split_part(email,'@',1), role = 'administrator';
update comforce.staff s
set user_id = u.id,
    display_name = coalesce(nullif(btrim(u.raw_user_meta_data->>'full_name'),''), s.display_name)
from auth.users u
where lower(u.email) = lower(s.email);
create unique index staff_user_id_unique on comforce.staff(user_id) where user_id is not null;

alter table comforce.requests add column submitted_by uuid;
alter table comforce.needs add column assigned_staff_id uuid references auth.users(id) on delete set null;
alter table comforce.history
  add column actor_uid uuid,
  add column actor_name text,
  add column actor_role text,
  add constraint history_actor_check check (
    (actor_uid is null and actor_name is null and actor_role is null)
    or (actor_uid is not null and length(btrim(actor_name)) between 1 and 80
        and actor_role in ('administrator','caseworker'))
  );
create index needs_assigned_staff_open_idx on comforce.needs(assigned_staff_id, status, follow_up);

create table comforce.audit_log (
  id bigint generated always as identity primary key,
  at timestamptz not null default clock_timestamp(),
  actor_uid uuid not null,
  actor_email text not null,
  actor_role text not null check (actor_role in ('administrator','caseworker')),
  action text not null check (action in (
    'request_submit','assign','direct','refer','decline','follow_up','fulfill','unmet','partner_contact','check_in'
  )),
  request_id uuid not null references comforce.requests(id),
  need_id uuid references comforce.needs(id),
  detail jsonb not null default '{}'::jsonb check (jsonb_typeof(detail) = 'object'),
  check ((action = 'request_submit') = (need_id is null))
);
create index audit_log_request_idx on comforce.audit_log(request_id, at desc, id desc);
create index audit_log_actor_idx on comforce.audit_log(actor_uid, at desc, id desc);
alter table comforce.audit_log enable row level security;
revoke all on comforce.audit_log from public, anon, authenticated;
revoke all on sequence comforce.audit_log_id_seq from public, anon, authenticated;

create function comforce.current_staff()
returns table(user_id uuid, email text, display_name text, role text)
language sql stable security definer set search_path = '' as $$
  select u.id, s.email,
    coalesce(nullif(btrim(s.display_name),''), nullif(btrim(u.raw_user_meta_data->>'full_name'),''), split_part(s.email,'@',1)),
    s.role
  from comforce.staff s
  join auth.users u on lower(u.email) = lower(s.email)
  where u.id = auth.uid()
    and u.email = auth.jwt()->>'email'
    and u.email_confirmed_at is not null
    and (s.user_id is null or s.user_id = u.id)
  limit 1;
$$;
revoke all on function comforce.current_staff() from public, anon, authenticated;

create or replace function comforce.is_staff() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists(select 1 from comforce.current_staff());
$$;
revoke all on function comforce.is_staff() from public, anon, authenticated;

create function public.staff_context(p_token text default null) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  workspace uuid := comforce.resolve_workspace(p_token,true);
  actor record;
  directory jsonb := '[]'::jsonb;
begin
  if workspace is not null then
    return jsonb_build_object('role','administrator','user_id',null,'display_name','Demo administrator',
      'can_assign',true,'staff','[]'::jsonb);
  end if;
  select * into actor from comforce.current_staff();
  if not found then raise insufficient_privilege using message='Verified staff access is required.'; end if;
  if actor.role = 'administrator' then
    select coalesce(jsonb_agg(jsonb_build_object(
      'user_id',u.id,
      'display_name',coalesce(nullif(btrim(s.display_name),''),nullif(btrim(u.raw_user_meta_data->>'full_name'),''),split_part(s.email,'@',1)),
      'role',s.role
    ) order by s.role,s.email),'[]'::jsonb) into directory
    from comforce.staff s join auth.users u on lower(u.email)=lower(s.email)
    where u.email_confirmed_at is not null and (s.user_id is null or s.user_id=u.id);
  end if;
  return jsonb_build_object('role',actor.role,'user_id',actor.user_id,'display_name',actor.display_name,
    'can_assign',actor.role='administrator','staff',directory);
end $$;

create or replace function public.submit_request(
  p_key uuid, p_services text[], p_description text, p_neighborhood text,
  p_contact_method text, p_contact text, p_source text, p_token text default null, p_family jsonb default null
) returns text language plpgsql security definer set search_path = '' as $$
declare
  workspace uuid := comforce.resolve_workspace(p_token,p_source in ('call','text'));
  receipt comforce.requests;
  family jsonb;
  actor_uid uuid;
  actor_email text;
  actor_role text;
begin
  if workspace is null and comforce.is_staff() then
    select user_id,email,role into actor_uid,actor_email,actor_role from comforce.current_staff();
  end if;
  if cardinality(p_services) is null or cardinality(p_services) not between 1 and 6
     or cardinality(p_services) <> (select count(distinct value) from unnest(p_services) value)
     or not (p_services <@ array['food','transportation','shelter','youth','other','family_support']) then
    raise exception using errcode = '22023', message = 'Choose one or more distinct services.';
  end if;
  if 'family_support' = any(p_services) then
    if (jsonb_typeof(p_family) = 'object' and jsonb_typeof(p_family->'support') = 'string'
        and jsonb_typeof(p_family->'safe_contact') = 'string'
        and length(btrim(p_family->>'support')) between 1 and 500
        and length(btrim(p_family->>'safe_contact')) between 1 and 300
        and coalesce(jsonb_typeof(jsonb_strip_nulls(p_family)->'agency'),'string')='string'
        and coalesce(jsonb_typeof(jsonb_strip_nulls(p_family)->'agency_reference'),'string')='string'
        and length(coalesce(p_family->>'agency','')) <= 120
        and length(coalesce(p_family->>'agency_reference','')) <= 80) is not true then
      raise exception using errcode = '22023', message = 'Describe the requested family support and safe follow-up.';
    end if;
    family := jsonb_strip_nulls(jsonb_build_object('support',btrim(p_family->>'support'),
      'safe_contact',btrim(p_family->>'safe_contact'),'agency',nullif(btrim(p_family->>'agency'),''),
      'agency_reference',nullif(btrim(p_family->>'agency_reference'),'')));
  elsif p_family is not null then
    raise exception using errcode = '22023', message = 'Select family support before adding family contact instructions.';
  end if;
  insert into comforce.requests(workspace_id,submission_key,description,neighborhood,contact_method,contact,source,family_support,submitted_by)
  values(workspace,p_key,btrim(p_description),p_neighborhood,p_contact_method,btrim(p_contact),p_source,family,
    case when workspace is null then actor_uid end)
  on conflict (workspace_id,submission_key) do nothing returning * into receipt;
  if found then
    insert into comforce.needs(request_id,service) select receipt.id,value from unnest(p_services) value;
    if actor_uid is not null then
      insert into comforce.audit_log(actor_uid,actor_email,actor_role,action,request_id,detail)
      values(actor_uid,actor_email,actor_role,'request_submit',receipt.id,
        jsonb_build_object('source',p_source,'services',to_jsonb(p_services)));
    end if;
  else
    select * into strict receipt from comforce.requests
    where workspace_id is not distinct from workspace and submission_key=p_key;
    if (receipt.description,receipt.neighborhood,receipt.contact_method,receipt.contact,receipt.source,receipt.family_support)
       is distinct from (btrim(p_description),p_neighborhood,p_contact_method,btrim(p_contact),p_source,family)
       or exists (select service from comforce.needs where request_id = receipt.id except select unnest(p_services))
       or exists (select unnest(p_services) except select service from comforce.needs where request_id = receipt.id) then
      raise exception using errcode = '22023', message = 'This submission key already has a different request.';
    end if;
  end if;
  return receipt.reference;
end $$;

create or replace function public.team_queue(p_token text default null) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  workspace uuid := comforce.resolve_workspace(p_token,true);
  actor_uid uuid;
  actor_role text;
begin
  if workspace is null then
    select user_id,role into actor_uid,actor_role from comforce.current_staff();
    if not found then raise insufficient_privilege using message='Verified staff access is required.'; end if;
  end if;
  return (select coalesce(jsonb_agg(to_jsonb(c) order by c.created_at desc,c.reference desc),'[]')
    from (
      select r.id,r.reference,r.description,r.neighborhood,r.contact_method,r.contact,r.source,r.created_at,r.family_support,
        (select jsonb_agg(to_jsonb(n) - 'request_id' || jsonb_build_object(
          'referrals', (select coalesce(jsonb_agg(to_jsonb(f) - 'need_id' order by f.sent_at desc,f.id),'[]')
                        from comforce.referrals f where f.need_id = n.id),
          'history', (select coalesce(jsonb_agg(to_jsonb(h) - 'need_id' - 'id' - 'operation_key' - 'actor_uid'
                        order by h.at desc,h.id desc),'[]') from comforce.history h where h.need_id = n.id)
        ) order by n.service) from comforce.needs n where n.request_id = r.id
          and (workspace is not null or actor_role='administrator' or n.assigned_staff_id=actor_uid)) as needs
      from comforce.requests r
      where r.workspace_id is not distinct from workspace
        and (workspace is not null or actor_role='administrator' or exists (
          select 1 from comforce.needs visible where visible.request_id=r.id and visible.assigned_staff_id=actor_uid
        ))
    ) c);
end $$;

drop function public.update_need(uuid,text,text,uuid,timestamptz,text,text,uuid);
create function public.update_need(
  p_need uuid, p_action text, p_value text default null, p_referral uuid default null,
  p_when timestamptz default null, p_token text default null, p_source text default null,
  p_key uuid default null, p_assignee uuid default null
) returns void language plpgsql security definer set search_path = '' as $$
declare
  workspace uuid := comforce.resolve_workspace(p_token,true);
  current_need comforce.needs;
  prior comforce.history;
  actor_uid uuid;
  actor_email text;
  actor_name text;
  actor_role text;
  target_name text;
  request_id uuid;
  label text := nullif(btrim(p_value),'');
  verified_source text;
  provider_name text := 'ComForce';
  detail text;
  occurred_at timestamptz := clock_timestamp();
begin
  if workspace is null then
    select user_id,email,display_name,role into actor_uid,actor_email,actor_name,actor_role
    from comforce.current_staff();
    if not found then raise insufficient_privilege using message='Verified staff access is required.'; end if;
    if p_action='assign' and actor_role<>'administrator' then
      raise insufficient_privilege using message='Only administrators can assign or reassign cases.';
    end if;
  elsif p_assignee is not null then
    raise exception using errcode='22023', message='Demo assignments use a worker name.';
  end if;

  select n.* into current_need from comforce.needs n join comforce.requests r on r.id=n.request_id
  where n.id=p_need and r.workspace_id is not distinct from workspace
    and (workspace is not null or actor_role='administrator' or n.assigned_staff_id=actor_uid)
  for update of n;
  if not found then raise insufficient_privilege using message='This need is unavailable or is not assigned to you.'; end if;
  -- PL/pgSQL cannot mix a row variable with other targets in one INTO list.
  request_id := current_need.request_id;
  if p_action='fulfill' and current_need.status='fulfilled' then return; end if;
  if p_action='check_in' then
    verified_source := nullif(btrim(p_source),'');
    if label is null or length(label)>500 or verified_source is null or length(verified_source)>120
       or p_key is null or p_when is null or not isfinite(p_when) or p_when>clock_timestamp()+interval '2 minutes' then
      raise exception using errcode='22023', message='Enter the check-in outcome, source and time it happened.';
    end if;
    select * into prior from comforce.history where need_id=p_need and operation_key=p_key;
    if found then
      if (prior.action,prior.detail,prior.source,prior.at) is distinct from (p_action,label,verified_source,p_when) then
        raise exception using errcode='22023', message='This check-in key was already used.';
      end if;
      return;
    end if;
  end if;
  if current_need.status<>'open' then raise exception 'This need is already closed.'; end if;
  case p_action
  when 'assign' then
    if workspace is null then
      if p_assignee is not null then
        select coalesce(nullif(btrim(s.display_name),''),nullif(btrim(u.raw_user_meta_data->>'full_name'),''),split_part(s.email,'@',1))
          into target_name
        from comforce.staff s join auth.users u on lower(u.email)=lower(s.email)
        where u.id=p_assignee and u.email_confirmed_at is not null and (s.user_id is null or s.user_id=u.id);
        if not found then raise exception using errcode='22023', message='Choose an active staff member.'; end if;
      end if;
      update comforce.needs set assigned_staff_id=p_assignee,owner=target_name
      where id=p_need;
      detail := coalesce(target_name,'Unassigned');
    else
      update comforce.needs set owner=label where id=p_need;
      detail := coalesce(label,'Unassigned');
    end if;
  when 'direct' then detail := 'ComForce will provide direct help.';
  when 'refer' then
    if label is null then raise exception 'Enter the partner name.'; end if;
    insert into comforce.referrals(need_id,partner) values(p_need,label);
    detail := label;
  when 'decline' then
    update comforce.referrals set declined_at=clock_timestamp()
      where id=p_referral and need_id=p_need and declined_at is null returning partner into detail;
    if not found then raise exception 'Choose a current referral for this need.'; end if;
  when 'partner_contact' then
    if label is null then raise exception 'Enter the partner contacted.'; end if;
    update comforce.needs set partner_contact=label where id=p_need;
    detail := label;
  when 'follow_up' then
    if p_when is null or not isfinite(p_when) then raise exception 'Choose a follow-up date and time.'; end if;
    update comforce.needs set follow_up=p_when where id=p_need;
    detail := to_char(p_when at time zone 'America/Chicago','Mon DD, YYYY HH24:MI') || ' Chicago';
  when 'check_in' then
    if current_need.follow_up is null then raise exception 'There is no pending follow-up on this need.'; end if;
    update comforce.needs set follow_up=null where id=p_need;
    detail := label;
    occurred_at := p_when;
  when 'fulfill' then
    if p_referral is not null then
      select partner into provider_name from comforce.referrals where id=p_referral and need_id=p_need and declined_at is null;
      if not found then raise exception 'Choose a current referral for this need.'; end if;
    end if;
    update comforce.needs set status='fulfilled',provider=provider_name,fulfilled_at=occurred_at,follow_up=null where id=p_need;
    detail := provider_name;
  when 'unmet' then
    if label is null then raise exception 'Enter an unmet reason.'; end if;
    update comforce.needs set status='unmet',unmet_reason=label,follow_up=null where id=p_need;
    detail := label;
  else raise exception 'Unknown need action.';
  end case;
  insert into comforce.history(need_id,action,detail,at,source,operation_key,actor_uid,actor_name,actor_role)
  values(p_need,p_action,detail,occurred_at,verified_source,case when p_action='check_in' then p_key end,
    actor_uid,actor_name,actor_role);
  if workspace is null then
    insert into comforce.audit_log(actor_uid,actor_email,actor_role,action,request_id,need_id,detail)
    values(actor_uid,actor_email,actor_role,p_action,request_id,p_need,
      jsonb_strip_nulls(jsonb_build_object('detail',detail,'assignee',case when p_action='assign' then p_assignee end)));
  end if;
end $$;

revoke all on function public.staff_context(text),
  public.update_need(uuid,text,text,uuid,timestamptz,text,text,uuid,uuid)
  from public,anon,authenticated;
grant execute on function public.staff_context(text),
  public.update_need(uuid,text,text,uuid,timestamptz,text,text,uuid,uuid)
  to anon,authenticated;
