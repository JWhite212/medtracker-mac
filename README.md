# medtracker-mac

Native macOS (Mac App Store) client for **MedTracker** — an offline-capable client of the
existing SvelteKit/Neon backend (`/api/v1`), with native local medication reminders.

- **Design spec:** in the `medication-tracker` repo → `docs/superpowers/specs/2026-07-25-macos-app-design.md`
- **API contract:** in the `medication-tracker` repo → `docs/api-v1-contract.md`

## Status: Phase 0 (backend) done. This repo starts with the go/no-go spike.

Before building the real app (a ~4-month effort), we validate the make-or-break assumption:
**does a scheduled local notification fire when the Mac app is fully quit, and does tapping
its action reach the app?** That's the whole reason for going native.

👉 **Start here: [`SETUP.md`](SETUP.md)** — creates a throwaway Xcode app from the sources in
[`Spike/`](Spike/) and walks through the exact tests + go/no-go criteria.

Once the spike is green, the real work begins — Phase 1: Swift domain port + GRDB + sync engine

- first screens. See the design spec's phased roadmap.
