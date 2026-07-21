-- Make the catalog ordering self-correcting instead of a frozen snapshot.
--
-- The seed order (20260721001000) is a hand-written promote list. That was the
-- right way to START — there is almost no measured data on the current
-- provider yet — but the wrong thing to LEAVE, because platform blocking is
-- reputation-based and only ratchets one way.
--
-- Mechanism, verified against Twilio Lookup v2 docs: the number-intelligence
-- products a platform can buy return line type, SMS-pumping risk, identity
-- match and (US-only) reassignment. There is NO "rented number" signal for
-- sale. Line-type lookup returns `mobile` for a rental SIM, because it IS a
-- real SIM on a real carrier with a real MCC/MNC — it only catches VoIP apps
-- like Google Voice. So platforms that block rentals must be using their own
-- reuse/reputation history of specific number ranges.
--
-- Two consequences: (1) better sourcing does not fix reputation blocking, and
-- (2) services that tolerate rental numbers today do so because they have not
-- built that history YET. Every winner is a decaying asset, so the ordering
-- must re-measure rather than trust a list written today.
--
-- Runs hourly from sync-smspool. Unmeasured services keep their seed position.
create or replace function public.apply_measured_service_ranking(
  p_min_sample integer default 8
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_moved integer;
begin
  with ranked as (
    select id, sort_order,
           observed_codes::numeric / nullif(observed_attempts, 0) as rate
    from public.services
    where observed_attempts >= p_min_sample
  ),
  moved as (
    update public.services s
    set sort_order = case
          when r.rate < 0.20 and s.sort_order < 5000 then 5000 + (s.sort_order % 1000)
          when r.rate >= 0.50 and s.sort_order >= 1000
            then 100 + round((1 - r.rate) * 90)::int
          else s.sort_order
        end
    from ranked r
    where s.id = r.id
      and s.sort_order is distinct from (case
          when r.rate < 0.20 and s.sort_order < 5000 then 5000 + (s.sort_order % 1000)
          when r.rate >= 0.50 and s.sort_order >= 1000
            then 100 + round((1 - r.rate) * 90)::int
          else s.sort_order
        end)
    returning 1
  )
  select count(*) into v_moved from moved;
  return v_moved;
end;
$$;

revoke execute on function public.apply_measured_service_ranking(integer)
  from public, anon, authenticated;
