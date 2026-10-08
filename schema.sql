-- Offline-first delivery tracker: Postgres schema
-- Key idea: drivers append immutable EVENTS (ids generated on the phone).
-- Order status is derived from events, so offline devices can't overwrite each other.

CREATE TABLE drivers (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text NOT NULL,
  phone       text UNIQUE NOT NULL,          -- also used for the SMS fallback
  active      boolean NOT NULL DEFAULT true
);

CREATE TABLE customers (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text NOT NULL,
  phone       text NOT NULL                  -- for SMS/WhatsApp updates
);

CREATE TABLE orders (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ref                 text UNIQUE NOT NULL,  -- short code, e.g. 1042 (used by SMS fallback)
  customer_id         uuid NOT NULL REFERENCES customers(id),
  address             text NOT NULL,
  lat                 double precision,
  lng                 double precision,
  notes               text,
  assigned_driver_id  uuid REFERENCES drivers(id),
  status              text NOT NULL DEFAULT 'pending'
                      CHECK (status IN ('pending','assigned','picked_up','delivered','failed')),
  last_event_at       timestamptz,           -- occurred_at of the event that set status
  updated_at          timestamptz NOT NULL DEFAULT now()  -- drives the pull cursor
);
CREATE INDEX orders_driver_updated ON orders (assigned_driver_id, updated_at);

-- Append-only. The primary key is generated ON THE DEVICE, which makes retries idempotent.
CREATE TABLE delivery_events (
  id           uuid PRIMARY KEY,             -- client-generated (crypto.randomUUID())
  order_id     uuid NOT NULL REFERENCES orders(id),
  driver_id    uuid NOT NULL REFERENCES drivers(id),
  device_id    text NOT NULL,
  type         text NOT NULL
               CHECK (type IN ('picked_up','delivered','failed','note')),
  payload      jsonb NOT NULL DEFAULT '{}',  -- e.g. {"reason":"customer absent"}
  occurred_at  timestamptz NOT NULL,         -- device clock: when it really happened
  received_at  timestamptz NOT NULL DEFAULT now(),  -- server clock: when we learned of it
  flagged      boolean NOT NULL DEFAULT false       -- e.g. order was reassigned meanwhile
);
CREATE INDEX events_order ON delivery_events (order_id, occurred_at);

-- Batched GPS points, uploaded in bulk when a connection appears.
CREATE TABLE location_points (
  id           uuid PRIMARY KEY,             -- client-generated
  driver_id    uuid NOT NULL REFERENCES drivers(id),
  lat          double precision NOT NULL,
  lng          double precision NOT NULL,
  recorded_at  timestamptz NOT NULL
);
CREATE INDEX location_driver_time ON location_points (driver_id, recorded_at DESC);

-- Photo/signature proof. The event is saved first; the file uploads later.
CREATE TABLE proofs (
  id           uuid PRIMARY KEY,             -- client-generated
  event_id     uuid NOT NULL REFERENCES delivery_events(id),
  kind         text NOT NULL CHECK (kind IN ('photo','signature')),
  storage_key  text,                         -- null until the file has uploaded
  uploaded_at  timestamptz
);
