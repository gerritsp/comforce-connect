-- Rollback-only TAP checks. Contributor: OpenAI Codex (GPT-6), access, atomicity and accounting tests.
begin;
set local plpgsql.check_asserts = on;
select '1..10';

-- One administrator, one caseworker and one visitor. The application authenticates with GoTrue.
insert into comforce.staff(email,display_name,role) values
  ('worker-test@example.invalid','Test Administrator','administrator'),
  ('caseworker-test@example.invalid','Test Caseworker','caseworker');
insert into auth.users(id,email,email_confirmed_at) values
  ('42667ca8-5125-4db0-834e-000000000001','worker-test@example.invalid',now()),
  ('42667ca8-5125-4db0-834e-000000000002','visitor-test@example.invalid',now()),
  ('42667ca8-5125-4db0-834e-000000000004','caseworker-test@example.invalid',now());

do $$
begin
  assert (select bool_and(relrowsecurity) from pg_class c join pg_namespace n on n.oid=c.relnamespace
          where n.nspname='comforce' and c.relkind='r'), 'private tables must enable RLS';
  assert not has_schema_privilege('anon','comforce','usage');
  assert not has_schema_privilege('authenticated','comforce','usage');
  assert to_regprocedure('public.team_queue()') is null;
  assert to_regprocedure('public.update_need(uuid,text,text,uuid,timestamptz)') is null;
  assert to_regprocedure('public.update_need(uuid,text,text,uuid,timestamptz,text,text,uuid)') is null;
  assert to_regprocedure('public.update_need(uuid,text,text,uuid,timestamptz,text,text,uuid,uuid)') is not null;
end $$;
select 'ok 1 - base tables are private and unscoped overloads are removed';

-- Existing records stay in the original scope. Only allowlisted verified staff can enter it.
set local role authenticated;
set local request.jwt.claims = '{"sub":"42667ca8-5125-4db0-834e-000000000001","email":"worker-test@example.invalid","role":"authenticated"}';
do $$
declare ref text;
begin
  ref := public.submit_request('42667ca8-5125-4db0-834e-000000000003',array['food','transportation'],
    'Fictional test','Harambee','email','test@example.invalid','web');
  assert ref like 'CF-%';
  assert ref = public.submit_request('42667ca8-5125-4db0-834e-000000000003',array['transportation','food'],
    'Fictional test','Harambee','email','test@example.invalid','web');
  begin
    perform public.submit_request('42667ca8-5125-4db0-834e-000000000003',array['food'],
      'Fictional test','Harambee','email','test@example.invalid','web');
    raise exception 'accepted different payload for the same key';
  exception when invalid_parameter_value then null;
  end;
end $$;
reset role;
do $$
begin
  assert (select count(*)=2 from comforce.needs n join comforce.requests r on r.id=n.request_id
          where r.submission_key='42667ca8-5125-4db0-834e-000000000003');
end $$;
select 'ok 2 - intake retries return one reference and one set of needs';

do $$
declare k uuid := gen_random_uuid();
begin
  begin
    perform public.submit_request(k,array['food','invalid'],'Test','Riverwest','text','4145550123','web');
    raise exception 'invalid service accepted';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.submit_request(k,array['food'],'Test','Riverwest','email','invalid','web');
    raise exception 'invalid contact accepted';
  exception when check_violation then null;
  end;
  assert not exists(select 1 from comforce.requests where submission_key=k);
end $$;
select 'ok 3 - invalid submissions leave no records';

set local role authenticated;
set local request.jwt.claims = '{"sub":"42667ca8-5125-4db0-834e-000000000002","email":"visitor-test@example.invalid","role":"authenticated","user_metadata":{"email":"worker-test@example.invalid"}}';
do $$
begin
  begin
    perform public.team_queue();
    raise exception 'visitor read staff queue';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.update_need(gen_random_uuid(),'direct');
    raise exception 'visitor could update a need';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
select 'ok 4 - a signed-in visitor cannot read or write team cases';

set local request.jwt.claims = '{"sub":"42667ca8-5125-4db0-834e-000000000001","email":"worker-test@example.invalid","role":"authenticated"}';
update auth.users set email_confirmed_at=null where email='worker-test@example.invalid';
do $$
begin
  assert not comforce.is_staff(), 'unconfirmed account gained staff access';
end $$;
update auth.users set email_confirmed_at=now() where email='worker-test@example.invalid';
do $$
declare
  food uuid; ride uuid; declined uuid; accepted uuid; req uuid;
  direct_key uuid := gen_random_uuid(); food_fulfill_key uuid := gen_random_uuid(); assign_key uuid := gen_random_uuid();
  first_referral_key uuid := gen_random_uuid(); decline_key uuid := gen_random_uuid(); follow_key uuid := gen_random_uuid();
  second_referral_key uuid := gen_random_uuid(); ride_fulfill_key uuid := gen_random_uuid();
begin
  select id into strict req from comforce.requests where submission_key='42667ca8-5125-4db0-834e-000000000003';
  select id into strict food from comforce.needs where request_id=req and service='food';
  select id into strict ride from comforce.needs where request_id=req and service='transportation';
  begin
    perform public.update_need(food,'direct');
    raise exception 'Update without an operation key was accepted';
  exception when invalid_parameter_value then null; end;
  perform public.update_need(food,'direct',p_key=>direct_key);
  perform public.update_need(food,'direct',p_key=>direct_key);
  perform public.update_need(food,'fulfill',p_key=>food_fulfill_key);
  perform public.update_need(food,'fulfill',p_key=>food_fulfill_key);
  assert (select count(*)=1 from comforce.history where need_id=food and action='fulfill');
  assert (select provider='ComForce' and fulfilled_at is not null from comforce.needs where id=food);
  perform public.update_need(ride,'assign',p_assignee=>'42667ca8-5125-4db0-834e-000000000004',p_key=>assign_key);
  perform public.update_need(ride,'assign',p_assignee=>'42667ca8-5125-4db0-834e-000000000004',p_key=>assign_key);
  begin
    perform public.update_need(ride,'assign',p_assignee=>'42667ca8-5125-4db0-834e-000000000001',p_key=>assign_key);
    raise exception 'Mismatched assignee retry was accepted';
  exception when invalid_parameter_value then null; end;
  perform public.update_need(ride,'refer','Example First',p_key=>first_referral_key);
  perform public.update_need(ride,'refer','Example First',p_key=>first_referral_key);
  select id into strict declined from comforce.referrals where need_id=ride;
  perform public.update_need(ride,'decline',p_referral=>declined,p_key=>decline_key);
  perform public.update_need(ride,'decline',p_referral=>declined,p_key=>decline_key);
  perform public.update_need(ride,'follow_up',p_when=>'2049-12-30 15:00-06',p_key=>follow_key);
  perform public.update_need(ride,'follow_up',p_when=>'2049-12-30 15:00-06',p_key=>follow_key);
  assert (select status='open' and follow_up is not null and owner='Test Caseworker'
          and assigned_staff_id='42667ca8-5125-4db0-834e-000000000004' from comforce.needs where id=ride);
  perform public.update_need(ride,'refer','Example Second',p_key=>second_referral_key);
  perform public.update_need(ride,'refer','Example Second',p_key=>second_referral_key);
  select id into strict accepted from comforce.referrals where need_id=ride and partner='Example Second';
  perform public.update_need(ride,'fulfill',p_referral=>accepted,p_key=>ride_fulfill_key);
  perform public.update_need(ride,'fulfill',p_referral=>accepted,p_key=>ride_fulfill_key);
  assert (select provider='Example Second' and follow_up is null from comforce.needs where id=ride);
  assert (select count(*)=2 from comforce.referrals where need_id=ride);
  assert not exists(select 1 from comforce.history where need_id in (food,ride) and operation_key is null);
  assert (select count(*) from comforce.need_operations where need_id in (food,ride)) =
         (select count(*) from comforce.history where need_id in (food,ride));
  assert (select bool_and(actor_uid='42667ca8-5125-4db0-834e-000000000001' and actor_role='administrator')
          from comforce.history where need_id in (food,ride) and actor_uid is not null);
end $$;
select 'ok 5 - confirmed staff can deliver, retry, record a refusal and reroute a ride';

-- Chicago is still in December at 04:30 UTC on Jan 1. Use a quiet future month
-- so edits made during a teammate walkthrough do not affect these totals.
update comforce.needs set fulfilled_at='2050-01-01 04:30+00' where request_id in (
  select id from comforce.requests where submission_key='42667ca8-5125-4db0-834e-000000000003'
);
update comforce.referrals set sent_at='2049-12-28 10:00-06',
  declined_at=case when declined_at is not null then '2049-12-29 10:00-06'::timestamptz end
where need_id in (select n.id from comforce.needs n join comforce.requests r on n.request_id=r.id
                  where r.submission_key='42667ca8-5125-4db0-834e-000000000003');
set local role authenticated;
do $$
declare totals record;
begin
  select * into strict totals from public.public_impact() where month='2049-12' and neighborhood is null;
  assert (totals.requests_helped,totals.needs_fulfilled,totals.referrals_made,totals.food_fulfilled)
         = (1,2,2,1);
  assert (select count(*)=7 from jsonb_object_keys(to_jsonb(totals)));
  assert (select count(*)=1 from public.public_impact() where month='2049-12' and neighborhood='Harambee');
  assert not exists(select 1 from public.public_impact() where month='2050-01');
end $$;
reset role;
select 'ok 6 - public aggregates use Chicago outcome months and count each request once';

do $$
declare ref text; youth uuid; unmet_key uuid := gen_random_uuid();
begin
  ref := public.submit_request(gen_random_uuid(),array['youth'],'Hours did not fit','Unknown',
    'phone','414-555-0142','text');
  select n.id into strict youth from comforce.needs n join comforce.requests r on n.request_id=r.id
    where r.reference=ref;
  perform public.update_need(youth,'unmet','Family declined the offered time.',p_key=>unmet_key);
  perform public.update_need(youth,'unmet','Family declined the offered time.',p_key=>unmet_key);
  assert (select status='unmet' and fulfilled_at is null and provider is null
          and unmet_reason='Family declined the offered time.' from comforce.needs where id=youth);
end $$;
select 'ok 7 - closed-unmet needs preserve their reason and contribute zero fulfillments';

set local role authenticated;
do $$
declare queue jsonb; ref text; assigned_open uuid; assign_key uuid := gen_random_uuid();
begin
  queue := public.team_queue();
  assert exists(select 1 from jsonb_array_elements(queue) c
                where c->>'description'='Fictional test' and jsonb_array_length(c->'needs')=2);
  ref := public.submit_request(gen_random_uuid(),array['shelter'],'Assigned caseworker test','Unknown',
    'email','assigned@example.invalid','web');
  -- The authenticated role cannot read the private comforce schema, so find the need through the staff queue.
  select (n->>'id')::uuid into strict assigned_open
    from jsonb_array_elements(public.team_queue()) c, jsonb_array_elements(c->'needs') n
    where c->>'reference'=ref;
  perform public.update_need(assigned_open,'assign',p_assignee=>'42667ca8-5125-4db0-834e-000000000004',p_key=>assign_key);
  perform set_config('comforce_test.assigned_open',assigned_open::text,true);
end $$;
reset role;
select 'ok 8 - staff queue includes both sibling needs';

-- A caseworker receives only assigned needs, even when another need belongs to the same request.
set local request.jwt.claims = '{"sub":"42667ca8-5125-4db0-834e-000000000004","email":"caseworker-test@example.invalid","role":"authenticated"}';
do $$
declare queue jsonb; context jsonb; ride uuid; food uuid; direct_key uuid := gen_random_uuid();
  assigned_open uuid := current_setting('comforce_test.assigned_open')::uuid;
begin
  -- Test 8 also assigned assigned_open to this caseworker, so exclude it to find the ride from test 5.
  select id into strict ride from comforce.needs
    where assigned_staff_id='42667ca8-5125-4db0-834e-000000000004' and id<>assigned_open;
  select n.id into strict food from comforce.needs n join comforce.requests r on r.id=n.request_id
    where r.submission_key='42667ca8-5125-4db0-834e-000000000003' and n.service='food';
  queue := public.team_queue();
  assert jsonb_array_length(queue)=2;
  assert not exists(select 1 from jsonb_array_elements(queue) q, jsonb_array_elements(q->'needs') n
                    where (n->>'id')::uuid=food);
  assert exists(select 1 from jsonb_array_elements(queue) q, jsonb_array_elements(q->'needs') n
                where (n->>'id')::uuid=ride);
  assert exists(select 1 from jsonb_array_elements(queue) q, jsonb_array_elements(q->'needs') n
                where (n->>'id')::uuid=assigned_open);
  context := public.staff_context();
  assert context->>'role'='caseworker' and context->>'display_name'='Test Caseworker'
    and context->>'can_assign'='false' and jsonb_array_length(context->'staff')=0;
  begin
    perform public.update_need(food,'direct');
    raise exception 'caseworker altered an unassigned sibling need';
  exception when insufficient_privilege then null; end;
  begin
    perform public.update_need(ride,'assign',p_assignee=>'42667ca8-5125-4db0-834e-000000000001');
    raise exception 'caseworker reassigned a case';
  exception when insufficient_privilege then null; end;
  perform public.update_need(assigned_open,'direct',p_key=>direct_key);
  assert exists(select 1 from comforce.history
    where need_id=assigned_open and action='direct'
      and actor_uid='42667ca8-5125-4db0-834e-000000000004' and actor_role='caseworker');
end $$;
select 'ok 9 - caseworkers see only assigned needs and cannot assign cases';

set local request.jwt.claims = '{"sub":"42667ca8-5125-4db0-834e-000000000001","email":"worker-test@example.invalid","role":"authenticated"}';
do $$
declare context jsonb;
begin
  context := public.staff_context();
  assert context->>'role'='administrator' and context->>'can_assign'='true';
  -- Other confirmed staff, such as a local Von sign-in from the setup guide, may also be listed.
  assert (select count(*) from jsonb_array_elements(context->'staff') s where s->>'user_id' in
    ('42667ca8-5125-4db0-834e-000000000001','42667ca8-5125-4db0-834e-000000000004'))=2;
  assert not exists(select 1 from comforce.audit_log where actor_uid is null);
  assert exists(select 1 from comforce.audit_log
    where actor_uid='42667ca8-5125-4db0-834e-000000000001' and action='request_submit');
  assert exists(select 1 from comforce.audit_log
    where actor_uid='42667ca8-5125-4db0-834e-000000000001' and action='assign'
      and (detail->>'assignee')::uuid='42667ca8-5125-4db0-834e-000000000004');
  assert exists(select 1 from comforce.audit_log
    where actor_uid='42667ca8-5125-4db0-834e-000000000004' and actor_role='caseworker' and action='direct');
end $$;
select 'ok 10 - administrators receive the staff directory and every real action is attributable';
rollback;
