# BillableTimer

A native macOS time-billing app. Multiple concurrent timers across
Client → Project → Entry, with totals by day, week, and two-week period, and
client-ready PDF invoices.

Built as a real Cocoa app — SwiftUI + system SQLite, no browser engine, no
runtime, no third-party packages.

Measured on an M4 with `phys_footprint` and CPU-time deltas over 20–30 second
windows:

| | |
|---|---|
| Memory, idle | **37 MB** |
| Memory, timers running | **~43 MB** |
| CPU, idle, window visible (settled) | **0–0.7%** |
| CPU, idle, window occluded or minimised | **0%** |
| CPU, 2 timers running | **~2%** |
| App bundle | **2.2 MB** |

A caution on measuring this: macOS stops rendering a window entirely once it is
**occluded**, and `ps %cpu` reports a decaying lifetime average rather than
current use. Both will happily tell you an idle SwiftUI app costs nothing when it
does not. Measure with CPU-*time* deltas over a fixed window, with the app's
window actually visible and the pointer away from it, and discard the first round
or two while SwiftUI settles.

## Build

```sh
./build.sh            # → build/BillableTimer.app
./build.sh --run      # build and launch
./build.sh --install  # also copy into /Applications
```

Requires Xcode's Swift toolchain (Swift 5.9+ / macOS 14+).

### Linux

`linux/` is a GTK4/libadwaita port with the same features, written in Python. It
needs no third-party packages beyond what a GNOME-capable desktop already has:
`gtk4`, `libadwaita`, `python-gobject`, `python-cairo`, and a sans font.

```sh
linux/run.sh                       # run from the source tree
linux/install.sh                   # install to ~/.local (launcher entry + `billabletimer`)
linux/install.sh --uninstall       # remove the app; billing data stays
cd linux && python3 -m unittest discover tests
```

The schema is identical, so the database moves between platforms: copy
`billabletimer.sqlite3` from the macOS path below to
`~/.local/share/BillableTimer/` with both apps quit. Paths of invoices issued on
the Mac stay recorded as Mac paths, so **Open PDF** will not find those files.

The Invoices page on both platforms can combine clients: tick several in the
**Bill to** menu. The first one ticked is billed, and the button lists them in
that order. All of their uninvoiced time goes on the same invoice with each line
labelled by client, and deleting the invoice releases all of it. No schema change
is involved, so a database with combined invoices opens on either platform.

Closing the window keeps the app in the system tray, which needs a host for
StatusNotifierItem (Omarchy's bar has one). Left-click opens the window;
right-click starts and stops timers. Trays have no text slot, so the live clock
is in the tooltip and menu, and the icon gains a red dot while anything runs.
Without a tray host, closing the window quits; running timers survive either way.

### The icon

The artwork is `Resources/hare-source.png`. `Icon/GenerateIcon.swift` composites
it onto the icon plate and emits every size the `.icns` needs:

```sh
swiftc -O -o /tmp/icongen Icon/GenerateIcon.swift
/tmp/icongen /tmp/preview preview          # 1024 / 128 / 64 / 32 PNGs to eyeball
/tmp/icongen /tmp/AppIcon.iconset          # the full set
iconutil -c icns /tmp/AppIcon.iconset -o Resources/AppIcon.icns
```

The source is a solid black hare on white. Drawing that bitmap directly would
stamp a white rectangle onto the plate, so instead its luminance becomes an alpha
mask — dark opaque, white transparent, with the antialiased edge carried through
as partial alpha. The silhouette is then painted in one flat colour, which keeps
the edges clean over any background. The generator also finds the ink bounds
itself and crops to them, so the artwork's margins don't affect the framing.

Because the subject is a solid shape rather than line-work, it survives
downsampling on its own — there is no dilation or brightness correction anywhere
in the pipeline, and every size comes from the same mask.

## How it works

### Data model

```
clients ──< projects ──< entries >── invoices
```

- **Clients** carry the default hourly rate and the billing address.
- **Projects** are the piece of work you bill against. A project can override
  its client's rate; otherwise it inherits it.
- **Entries** are time. A running timer is simply an entry with `ended_at IS NULL`.
- **Invoices** stamp their entries with `invoice_id`, which locks those entries
  against editing or deletion so a sent invoice always matches its underlying time.

Everything lives in one SQLite file:

```
~/Library/Application Support/BillableTimer/billabletimer.sqlite3
```

Back up that file and your entire billing history travels with it. To start over,
quit the app and delete the `BillableTimer` folder at that path.

### Two design decisions worth knowing

**Entries are attributed to the day they started.** Work from 10pm Monday to
1am Tuesday counts entirely toward Monday. This keeps entries atomic — an entry
is never split across two days, two periods, or two invoices.

**Elapsed time is always derived from stored wall-clock timestamps**, never from
counting ticks. Sleep, wake, app quit, and crash are all handled for free: a timer
started before a three-hour nap shows three more hours when you come back, and a
timer left running survives a restart.

### Entering time by hand

Entries → **Add Entry** takes time two ways, switchable with a segmented control:

- **Duration** (the default) — pick when the work started, then type hours and/or
  minutes. Either field may be left blank, so `45` minutes alone or `2` hours
  alone both work, and minutes over 59 roll up (`0h 90m` = 1.50). Hours also
  accepts a decimal if that's your habit (`1.5`).
- **Start & End** — pick both clock times directly.

Either way the editor shows the **decimal hours** live as you type — `1h 45m`
reads out as `1.75 hours` — because decimal hours is the unit that reaches the
invoice. Switching between the two modes carries the current value across rather
than discarding it.

### Concurrent timers

Starting a timer never stops another one — several can run at once by design.
Note that this means a day's total *can* exceed 24 hours; the reports show you
exactly what you recorded rather than silently reconciling it.

### Billing periods

- **Week** starts Sunday or Monday (Settings).
- **Two-week periods** tile the calendar outward in both directions from an
  anchor date you set, so past periods line up as consistently as future ones.
- **Reports opens on today**, under the Day tab, rather than inheriting wherever
  the period controls were left in Entries.
- **Midnight rolls the view over.** The browsed period is anchored to a reference
  date, and a session left open overnight would otherwise keep pointing at the day
  the app launched — including the menu bar's "Today" total. A day-change
  notification (and a re-check on wake, since sleeping through midnight doesn't
  reliably deliver one) carries the view onto the new day. If you deliberately
  navigated to a past period with the arrows, you are left where you put yourself.

## Layout

```
Sources/BillableTimer/
  BillableTimerApp.swift    @main — window, menu bar extra, launch failure handling
  AppModel.swift            observable state, timer engine, report aggregation
  DB/
    Database.swift          libsqlite3 wrapper (prepare/bind/step/transactions)
    Schema.swift            versioned migrations via PRAGMA user_version
    Models.swift            Client, Project, Entry, Invoice, AppSettings
    Store.swift             every query the app runs
  Views/
    RootView.swift          sidebar, error banner, shared components, LiveDuration
    TimersView.swift        running timers + one-tap start grid
    EntriesView.swift       browse, edit, and add time manually
    ReportsView.swift       totals, daily bars, client/project breakdown
    ClientsView.swift       client + project CRUD and rates
    InvoicesView.swift      select, preview, generate, and track invoices
    SettingsView.swift      business identity, periods, data location
    MenuBarView.swift       status-bar panel
  Invoice/
    InvoicePDF.swift        CoreGraphics invoice renderer with pagination
  Util/
    Periods.swift           day / week / two-week range math
    Formatters.swift        durations, decimal hours, currency
```

### Why the status item is AppKit, not `MenuBarExtra`

SwiftUI's `MenuBarExtra` with `.menuBarExtraStyle(.window)` re-lays out
continuously even while its panel is closed. Bisected on this app: removing the
scene took idle CPU from **5.5% to 0.04%**, and it still cost **3.56%** with a
static `Image` label and a single `Text` as its content — so it is the style's own
machinery, not the views inside it. (`.menuBarExtraStyle(.menu)` measures 0.00%
but cannot host an interactive panel.)

`MenuBarController` therefore drives an `NSStatusItem` directly and builds an
`NSPopover` only when clicked, tearing the hosted view down on close. Same panel,
0.00% when idle. Updating the ticking clock in the menu bar is a string assignment
on the status button rather than a SwiftUI view update.

### Modifiers that are always attached but usually empty

`RootView` composes the sidebar footer with a `VStack` and the error banner with a
`ZStack`, rather than the more natural `.safeAreaInset(edge: .bottom)` and
`.overlay(alignment: .top)`. Those modifiers are attached unconditionally, so
SwiftUI keeps laying out their content on every frame even when the `@ViewBuilder`
inside resolves to `EmptyView` — and both are empty almost all the time, since
usually nothing is running and there is no error.

Measured back to back on an otherwise idle machine, with the window visible: the
modifier version settled at ~2%, the `VStack`/`ZStack` version at 0–0.7%. Same UI,
but the conditional is a real branch instead of an empty modifier.

### A note on the clock

`Clock` is deliberately a separate `ObservableObject` from `AppModel`. If the
ticking value lived on the model, every one-second tick would invalidate every
view observing it — the whole entry table, the project grid, and the description
fields on running timers. Instead, only small leaf views (`LiveDuration`) observe
`Clock`, while tables and totals run off a coarse 15-second tick. That is the
difference between 5–10% CPU and 0–3%.
