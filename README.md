# Offline-First Delivery Tracker: Database Schema

A PostgreSQL schema for a delivery tracking system where drivers work with unreliable or no connectivity. Drivers' phones record what happens as **immutable events**, and the server derives each order's status from those events. Because devices only ever *append* data, two offline phones can never overwrite each other's changes.

## Core Design Ideas

| Idea | How the schema supports it |
|------|----------------------------|
| **Append-only events** | Drivers insert rows into `delivery_events`; they never edit an order directly. |
| **Client-generated IDs** | `delivery_events`, `location_points`, and `proofs` use UUIDs created on the phone (e.g. `crypto.randomUUID()`). If a sync request is retried, the same primary key is sent again, so duplicates are rejected and retries are **idempotent**. |
| **Two clocks** | `occurred_at` is the device clock (when it really happened); `received_at` is the server clock (when we found out). |
| **Derived status** | `orders.status` and `orders.last_event_at` are set from the latest relevant event. |
| **Deferred uploads** | A proof's event is saved first; the photo/signature file uploads later, filling in `storage_key`. |
| **SMS fallback** | `drivers.phone` and `orders.ref` (a short code like `1042`) let a driver report status by text message when there is no data connection. |

## Tables

### `drivers`
People who deliver orders.

| Column | Type | Notes |
|--------|------|-------|
| `id` | uuid, PK | Defaults to `gen_random_uuid()` |
| `name` | text | Required |
| `phone` | text | Required, unique. Also used for the SMS fallback |
| `active` | boolean | Defaults to `true` |

### `customers`
People receiving orders.

| Column | Type | Notes |
|--------|------|-------|
| `id` | uuid, PK | Defaults to `gen_random_uuid()` |
| `name` | text | Required |
| `phone` | text | Required. For SMS/WhatsApp updates |

### `orders`
A delivery to be made.

| Column | Type | Notes |
|--------|------|-------|
| `id` | uuid, PK | |
| `ref` | text | Required, unique short code (e.g. `1042`) used by the SMS fallback |
| `customer_id` | uuid, FK | → `customers(id)` |
| `address` | text | Required |
| `lat`, `lng` | double precision | Optional coordinates |
| `notes` | text | Optional |
| `assigned_driver_id` | uuid, FK | → `drivers(id)`, nullable |
| `status` | text | One of `pending`, `assigned`, `picked_up`, `delivered`, `failed`. Defaults to `pending` |
| `last_event_at` | timestamptz | `occurred_at` of the event that set the current status |
| `updated_at` | timestamptz | Drives the pull cursor for syncing changes down to devices |

**Index:** `orders_driver_updated (assigned_driver_id, updated_at)`, so a driver's phone can efficiently ask "what changed for me since my last sync?"

### `delivery_events`
The append-only log of what happened. This is the source of truth.

| Column | Type | Notes |
|--------|------|-------|
| `id` | uuid, PK | **Client-generated** |
| `order_id` | uuid, FK | → `orders(id)` |
| `driver_id` | uuid, FK | → `drivers(id)` |
| `device_id` | text | Which phone sent it |
| `type` | text | One of `picked_up`, `delivered`, `failed`, `note` |
| `payload` | jsonb | Extra details, e.g. `{"reason":"customer absent"}` |
| `occurred_at` | timestamptz | Device clock |
| `received_at` | timestamptz | Server clock, defaults to `now()` |
| `flagged` | boolean | Marks events needing review, e.g. the order was reassigned while the driver was offline |

**Index:** `events_order (order_id, occurred_at)`, for reading an order's history in order.

### `location_points`
GPS breadcrumbs, uploaded in batches whenever a connection appears.

| Column | Type | Notes |
|--------|------|-------|
| `id` | uuid, PK | **Client-generated** |
| `driver_id` | uuid, FK | → `drivers(id)` |
| `lat`, `lng` | double precision | Required |
| `recorded_at` | timestamptz | When the point was captured |

**Index:** `location_driver_time (driver_id, recorded_at DESC)`, for a driver's latest position or recent trail.

### `proofs`
Photo or signature proof of delivery.

| Column | Type | Notes |
|--------|------|-------|
| `id` | uuid, PK | **Client-generated** |
| `event_id` | uuid, FK | → `delivery_events(id)` |
| `kind` | text | `photo` or `signature` |
| `storage_key` | text | `NULL` until the file has actually uploaded |
| `uploaded_at` | timestamptz | `NULL` until upload completes |

## Relationships

```
customers ──< orders >── drivers (assigned_driver_id)
                │
                └──< delivery_events >── drivers
                          │
                          └──< proofs

drivers ──< location_points
```

## How Syncing Is Meant to Work

**Phone → server (push)**
1. The driver taps "Delivered". The phone creates an event with a new UUID and the device's current time as `occurred_at`, and stores it locally.
2. When connectivity returns, the phone sends all pending events. The server inserts them, ignoring any whose `id` already exists (this is what makes retries safe).
3. The server updates the order's `status` and `last_event_at` based on the event with the latest `occurred_at`. Late-arriving older events don't clobber newer ones.
4. If the order was reassigned to another driver in the meantime, the event is still stored but gets `flagged = true` for review.
5. Proof files upload separately; once done, `storage_key` and `uploaded_at` are filled in.

**Server → phone (pull)**
- The phone asks for orders where `assigned_driver_id` is the driver and `updated_at` is greater than its last cursor.

## Setup

`gen_random_uuid()` is built in from PostgreSQL 13 onward. On older versions, enable the extension first:

```sql
CREATE EXTENSION IF NOT EXISTS pgcrypto;
```

Then load the schema:

```bash
psql -d your_database -f schema.sql
```

## Notes and Possible Next Steps

- `orders.status` is a denormalized cache of the event log. If it ever looks wrong, it can be recomputed from `delivery_events`.
- Device clocks can be wrong. Comparing `occurred_at` with `received_at` can help detect badly skewed clocks.
- Consider adding an index on `delivery_events (received_at)` or `proofs (event_id)` if those become common query paths.
