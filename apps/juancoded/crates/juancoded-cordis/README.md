# juancoded-cordis

The composition core of the Rust daemon: a keyed service registry, RAII effect guards,
a diffable entry list, a typed event bus, and `dump-config`. Everything else in the
migration mounts into this.

The ideas come from [cordis](https://github.com/deepseek-ai/deepseek-harness)
(`docs/cordis-primer.md`, `docs/cordis-tutorial/06-composition-and-hmr.md`), not the
framework. Each one lands somewhere Rust already wanted it.

## The five ideas, and where they live

| Idea | Module | Shape here |
| --- | --- | --- |
| A context is a repository of services | `service` | `ServiceRegistry`, keyed by `Service::KEY`, contract in `Service::Api` (`dyn Trait`) |
| Registrations are reversible effects | `effect` | `Effect` unregisters on `Drop`; `EffectScope` unwinds in reverse |
| Declare dependencies, not boot order | `loader` | `Plugin::inject()` names keys; the loader settles until nothing new can start |
| The entry list is the composition | `entry` | Ordered rows with stable ids and `disabled`; diffed by id |
| Typed events with explicit dispatch modes | `bus` | One trait per mode, so the mode is compiler-checked |

Not ported: groups/isolate realms, and per-agent scoped registration with shadowing.
Both exist so tenants cannot see each other's services. This daemon serves one app.

## What "reversible" buys

```rust
let guard = bus.on::<SessionOutput, _>("terminal.feed", |frame| { /* ... */ });
drop(guard); // the listener is gone
```

`Effect` is `#[must_use]`, so ignoring the return value is a compile-time warning
rather than a silent leak, and dropping it is the *only* way to unregister: there is no
second teardown path to forget. `EffectScope` pops rather than letting `Vec` drop
front-to-back, so a plugin tears down in the reverse of the order it built.

Disposers hold weak references to the registry they came from. Dropping a guard after
`shutdown()`, or after the registry itself is freed, is a no-op. `Effect::dispose()`
takes the disposer out of the guard, so the `Drop` that follows finds nothing to run.

## Dispatch modes

| Mode | Trait | Register | Dispatch | Awaited | Returns |
| --- | --- | --- | --- | --- | --- |
| observe | `ObserveEvent` | `on` | `emit` | no | no |
| around | `AroundEvent` | `around` | `waterfall` | no | yes |
| fan-out | `FanOutEvent` | `on_fan_out` | `parallel` | yes | no |
| ordered | `SerialEvent` | `on_serial` | `serial` | yes | yes |

cordis documents the mode in a doc tag and checks dispatch sites with a generator.
Here the mode *is* the trait the event implements, so a mismatched dispatch does not
compile and there is nothing to generate.

`around` is real around-middleware: a listener gets `(&mut request, next)`, calls
`next.run(request)` to delegate, or returns without it to own the decision. The
dispatch site supplies the terminal behaviour, which runs only if every listener
delegates. `serial` awaits listeners in registration order and stops at the first
`Some`.

## PENDING is never silent

cordis's own tutorial names this as its footgun: a plugin whose `inject` lists a
service nobody provides waits forever, printing nothing. Here every `apply` logs a
warning per pending fiber, `LoadReport::diagnostics()` returns them as sentences, and
`dump-config` prints the missing key on the row.

## dump-config

```
$ cargo run -p juancoded-cordis --example dump_config
juancoded config: 5 entries (4 active, 1 pending, 0 disabled, 0 failed), 2 services, 4 events

entries
├─ [ACTIVE  ] terminal      vt-terminal   effects=1
├─ [ACTIVE  ] pty           core-pty      effects=2
├─ [ACTIVE  ] input-guard   input-guard   needs=pty  effects=1
├─ [ACTIVE  ] pty-to-grid   pty-to-grid   needs=pty,terminal  effects=3
└─ [PENDING ] activity-log  activity-log  needs=transcripts  missing=transcripts

services
├─ pty       <- pty
└─ terminal  <- terminal

events
├─ provider.resolveBin  ordered  1  path.lookup
├─ session.exit         fan-out  1  terminal.close
├─ session.input        around   2  guard.live-session,pty.write
└─ session.output       observe  1  terminal.feed
```

The second column is the entry id, which is the same string `EntryList::set_disabled`
takes: reading the output tells you what to type to change it. Services and events are
sorted by name, because `TypeId` ordering is not stable across builds and a diagnostic
that reorders itself between runs is not a diagnostic.

## The tree it boots

Two real services, mounted as thin adapters over the crates that already own the work:

- `terminal` — `services::terminal::VtTerminals` over `juancoded-vt`, one real
  `alacritty_terminal` grid per session, handed out as value snapshots.
- `pty` — `services::pty::PtyHost` over `juancoded_core::pty::PtyHandle`, real
  `portable-pty` children with their environment untouched.

And the plugins over them: `vt-terminal` and `core-pty` claim the keys, `pty-to-grid`
feeds output into the grid and owns the input write, `input-guard` refuses input to a
session with no live pty, and `activity-log` sits PENDING on a `transcripts` service
that does not exist yet.

`tests/booted_tree.rs` runs the whole thing against a real `/bin/cat` in a real pty.

## Run it

```sh
cargo run -p juancoded-cordis --example dump_config
cargo test -p juancoded-cordis
```

Nothing here starts on its own, binds a port, or spawns a child until an entry list is
applied by hand.
