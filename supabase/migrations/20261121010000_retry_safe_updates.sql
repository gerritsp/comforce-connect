-- Make every case update idempotent after staff roles and auditing are installed. The registry keeps only a hash
-- of the request payload while allowing an exact retry to return successfully.
create table comforce.need_operations (
  need_id uuid not null references comforce.needs,
  operation_key uuid not null,
  request_hash bytea not null check (length(request_hash) = 32),
  primary key (need_id, operation_key)
);
alter table comforce.need_operations enable row level security;
revoke all on comforce.need_operations from public, anon, authenticated;

-- Preserve retry behavior for check-ins written before the operation registry
-- existed. Check-ins were the only updates that previously had operation keys.
insert into comforce.need_operations(need_id, operation_key, request_hash)
select need_id, operation_key, sha256(convert_to(jsonb_build_object(
  'action', action,
  'value', detail,
  'referral', null,
  'when', extract(epoch from at),
  'source', source,
  'assignee', null
)::text,'UTF8'))
from comforce.history
where operation_key is not null;

create function comforce.need_operation_hash(
  p_action text, p_value text, p_referral uuid, p_when timestamptz, p_source text, p_assignee uuid
) returns bytea
language sql immutable set search_path = '' as $$
  select sha256(convert_to(jsonb_build_object(
    'action', p_action,
    'value', nullif(btrim(p_value),''),
    'referral', p_referral,
    'when', extract(epoch from p_when),
    'source', nullif(btrim(p_source),''),
    'assignee', p_assignee
  )::text,'UTF8'))
$$;

-- Demo workspaces copy the template's private idempotency records along with
-- its history so every copied operation retains the same invariant.
create or replace function public.create_demo_workspace() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  workspace uuid;
  staff_token text := replace(gen_random_uuid()::text || gen_random_uuid()::text,'-','');
  resident_token text := replace(gen_random_uuid()::text || gen_random_uuid()::text,'-','');
  template uuid := comforce.template_id();
begin
  if not exists(select 1 from comforce.requests where workspace_id = template) then
    raise exception 'The fictional demo seed has not been loaded.';
  end if;
  insert into comforce.workspaces(staff_digest,resident_digest)
    values(sha256(convert_to(staff_token,'UTF8')),sha256(convert_to(resident_token,'UTF8'))) returning id into workspace;
  insert into comforce.requests(workspace_id,id,submission_key,created_at,neighborhood,description,contact_method,contact,source,family_support)
    select workspace,comforce.copy_id(workspace,r.id),gen_random_uuid(),r.created_at,r.neighborhood,r.description,
           r.contact_method,r.contact,r.source,r.family_support
    from comforce.requests r where r.workspace_id=template order by r.created_at,r.id;
  insert into comforce.needs(id,request_id,service,status,owner,follow_up,provider,fulfilled_at,unmet_reason,partner_contact)
    select comforce.copy_id(workspace,n.id),comforce.copy_id(workspace,n.request_id),
           n.service,n.status,n.owner,n.follow_up,n.provider,n.fulfilled_at,n.unmet_reason,n.partner_contact
    from comforce.needs n join comforce.requests r on r.id=n.request_id where r.workspace_id=template;
  insert into comforce.referrals(id,need_id,partner,sent_at,declined_at)
    select comforce.copy_id(workspace,f.id),comforce.copy_id(workspace,f.need_id),f.partner,f.sent_at,f.declined_at
    from comforce.referrals f join comforce.needs n on n.id=f.need_id join comforce.requests r on r.id=n.request_id
    where r.workspace_id=template;
  insert into comforce.history(need_id,at,action,detail,source,operation_key)
    select comforce.copy_id(workspace,h.need_id),h.at,h.action,h.detail,h.source,h.operation_key
    from comforce.history h join comforce.needs n on n.id=h.need_id join comforce.requests r on r.id=n.request_id
    where r.workspace_id=template order by h.id;
  insert into comforce.need_operations(need_id,operation_key,request_hash)
    select comforce.copy_id(workspace,o.need_id),o.operation_key,o.request_hash
    from comforce.need_operations o join comforce.needs n on n.id=o.need_id
    join comforce.requests r on r.id=n.request_id where r.workspace_id=template;
  insert into comforce.need_operations(need_id,operation_key,request_hash)
    select comforce.copy_id(workspace,h.need_id),h.operation_key,
           comforce.need_operation_hash(h.action,h.detail,null,h.at,h.source,null)
    from comforce.history h join comforce.needs n on n.id=h.need_id
    join comforce.requests r on r.id=n.request_id
    where r.workspace_id=template and h.operation_key is not null
    on conflict do nothing;
  return jsonb_build_object('workspace_id',workspace,'staff_token',staff_token,'resident_token',resident_token);
end $$;

create or replace function public.update_need(
  p_need uuid, p_action text, p_value text default null, p_referral uuid default null,
  p_when timestamptz default null, p_token text default null, p_source text default null,
  p_key uuid default null, p_assignee uuid default null
) returns void language plpgsql security definer set search_path = '' as $$
declare
  workspace uuid := comforce.resolve_workspace(p_token,true);
  current_need comforce.needs;
  prior comforce.need_operations;
  actor_uid uuid;
  actor_email text;
  actor_name text;
  actor_role text;
  target_name text;
  request_id uuid;
  label text := nullif(btrim(p_value),'');
  verified_source text := nullif(btrim(p_source),'');
  request_hash bytea := comforce.need_operation_hash(p_action,p_value,p_referral,p_when,p_source,p_assignee);
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
  if p_key is null then
    raise exception using errcode='22023', message='Every update requires an operation key.';
  end if;
  select * into prior from comforce.need_operations where need_id=p_need and operation_key=p_key;
  if found then
    if prior.request_hash is distinct from request_hash then
      raise exception using errcode='22023', message='This operation key was already used for a different update.';
    end if;
    return;
  end if;
  if p_action='check_in' and
     (label is null or length(label)>500 or verified_source is null or length(verified_source)>120
      or p_when is null or not isfinite(p_when) or p_when>clock_timestamp()+interval '2 minutes') then
    raise exception using errcode='22023', message='Enter the check-in outcome, source and time it happened.';
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
      update comforce.needs set assigned_staff_id=p_assignee,owner=target_name where id=p_need;
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
  values(p_need,p_action,detail,occurred_at,case when p_action='check_in' then verified_source end,p_key,
    actor_uid,actor_name,actor_role);
  insert into comforce.need_operations(need_id,operation_key,request_hash)
  values(p_need,p_key,request_hash);
  if workspace is null then
    insert into comforce.audit_log(actor_uid,actor_email,actor_role,action,request_id,need_id,detail)
    values(actor_uid,actor_email,actor_role,p_action,request_id,p_need,
      jsonb_strip_nulls(jsonb_build_object('detail',detail,'assignee',case when p_action='assign' then p_assignee end)));
  end if;
end $$;

revoke all on function comforce.need_operation_hash(text,text,uuid,timestamptz,text,uuid) from public,anon,authenticated;
