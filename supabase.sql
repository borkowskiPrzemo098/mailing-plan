-- MAILING – wspólny plan wysyłek mailingów (pon / śr / pt, z możliwością przeniesienia).
-- Uruchom raz w Supabase → SQL Editor. Brak logowania: dostęp tylko przez funkcje mail_* poniżej.

create table if not exists mail_wysylki(
  id bigint generated always as identity primary key,
  dzien date not null,
  temat text not null default '',
  status text not null default 'plan' check (status in ('plan', 'gotowy', 'wyslany')),
  notatka text not null default '',
  przeniesiono_z date,
  usuniety boolean not null default false,
  utworzono timestamptz not null default now(),
  zmieniono timestamptz not null default now()
);
create index if not exists mail_wysylki_dzien on mail_wysylki(dzien) where not usuniety;

alter table mail_wysylki enable row level security;

-- Dzień liczony po czasie polskim, niezależnie od zegara urządzenia.
create or replace function mail_dzis() returns date language sql stable
as $$ select (now() at time zone 'Europe/Warsaw')::date $$;

create or replace function mail_lista(p_od date, p_do date) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'dzis', mail_dzis(),
    'wpisy', coalesce((select jsonb_agg(to_jsonb(w) - 'usuniety' order by w.dzien, w.id)
                        from mail_wysylki w where not w.usuniety and w.dzien between p_od and p_do), '[]'),
    'nastepny', (select to_jsonb(w) - 'usuniety' from mail_wysylki w
                  where not w.usuniety and w.dzien >= mail_dzis() and w.status <> 'wyslany'
                  order by w.dzien, w.id limit 1)
  )
$$;

-- p_id = null → nowy wpis. Zmiana daty istniejącego wpisu zapamiętuje dzień, z którego go przeniesiono.
create or replace function mail_zapisz(p_id bigint, p_dzien date, p_temat text, p_status text, p_notatka text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v mail_wysylki;
begin
  if p_dzien is null then raise exception 'Brak daty wysyłki'; end if;
  if p_id is null then
    insert into mail_wysylki(dzien, temat, status, notatka)
    values (p_dzien, left(coalesce(p_temat, ''), 300), coalesce(p_status, 'plan'), left(coalesce(p_notatka, ''), 4000))
    returning * into v;
  else
    update mail_wysylki set
      przeniesiono_z = case when dzien <> p_dzien then coalesce(przeniesiono_z, dzien) else przeniesiono_z end,
      dzien = p_dzien,
      temat = left(coalesce(p_temat, ''), 300),
      status = coalesce(p_status, status),
      notatka = left(coalesce(p_notatka, ''), 4000),
      zmieniono = now()
    where id = p_id and not usuniety
    returning * into v;
    if v.id is null then raise exception 'Ten mailing został w międzyczasie usunięty'; end if;
    -- Powrót na pierwotny dzień kasuje znacznik przeniesienia.
    if v.przeniesiono_z = v.dzien then
      update mail_wysylki set przeniesiono_z = null where id = v.id returning * into v;
    end if;
  end if;
  return to_jsonb(v) - 'usuniety';
end $$;

create or replace function mail_status(p_id bigint, p_status text) returns void
language sql security definer set search_path = public as $$
  update mail_wysylki set status = p_status, zmieniono = now() where id = p_id and not usuniety
$$;

-- Usuwanie jest miękkie: wpis da się przywrócić („Cofnij”). Kosz czyszczony po 90 dniach.
create or replace function mail_usun(p_id bigint) returns void
language sql security definer set search_path = public as $$
  update mail_wysylki set usuniety = true, zmieniono = now() where id = p_id;
  delete from mail_wysylki where usuniety and zmieniono < now() - interval '90 days';
$$;

create or replace function mail_przywroc(p_id bigint) returns void
language sql security definer set search_path = public as $$
  update mail_wysylki set usuniety = false, zmieniono = now() where id = p_id
$$;

revoke all on function mail_lista(date, date), mail_zapisz(bigint, date, text, text, text),
  mail_status(bigint, text), mail_usun(bigint), mail_przywroc(bigint) from public;
grant execute on function mail_lista(date, date), mail_zapisz(bigint, date, text, text, text),
  mail_status(bigint, text), mail_usun(bigint), mail_przywroc(bigint) to anon, authenticated;
