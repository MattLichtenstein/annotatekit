<img src=".claude-plugin/icon.png" width="64" alt="AnnotateKit icon">

# AnnotateKit

[![CI](https://github.com/ooolzhas/annotatekit/actions/workflows/ci.yml/badge.svg)](https://github.com/ooolzhas/annotatekit/actions/workflows/ci.yml)
[![iOS 17+](https://img.shields.io/badge/iOS-17%2B-blue.svg)](Package.swift)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138.svg)](Package.swift)
[![npm](https://img.shields.io/npm/v/annotate-ios)](https://www.npmjs.com/package/annotate-ios)
[![MIT license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**[AnnotateKit](https://annotatekit.com)** turns drawings and comments inside your iOS app into
prompts for your coding agent. Tap, draw, and send to Claude, Codex, Cursor, or any MCP client.

Works with SwiftUI, UIKit, [React Native and Expo](#react-native-and-expo), on device and in the
simulator. Everything is behind `#if DEBUG`, so Release builds carry none of it.

## Install

### Optional T3 routing (maintained fork)

Set `AnnotateOptions.t3ProjectID` and use a **dedicated** output directory ending in
`.annotate/t3` (phone: `Documents/.annotate/t3`). Holding Send with ready notes opens
its native menu; keep holding, drag to New thread or one of five recent project
threads, and release to send. Lifting without selecting leaves the menu open for a tap.
Normal Send creates a thread when none is selected; later taps reuse it until the app
process closes. Working destinations receive a queued next turn. The current
destination is shown only inside the menu.
New annotation threads follow T3's effective workspace preference (including project
overrides and inherited `t3.json` defaults). New-checkout mode asks T3 to create and
bind a worktree from the project's default branch, honoring its start-from-origin
setting. Existing-thread sends keep that thread's checkout. The resolved launch
arguments are saved before creation, so retrying after a settings change cannot
create a second thread or change its workspace. If settings cannot be read, the
batch remains pending rather than silently using the project root. Pre-upgrade
interrupted launches preserve their original request and implicit root binding.

The first batch is the new thread's opening message, including its uploaded
attachments. This lets T3 generate the checkout branch from the real feedback using
its configured naming mode, prefix, and instructions. T3 may briefly show a temporary
name while generating it. Existing destination branches are unchanged. Opening
messages are not queued again; accepted run IDs make receipt-write retries safe.

Run this fork's separate Mac receiver (Node 22+ and Xcode required):

```sh
swift run annotate-t3 login --origin http://127.0.0.1:3773
swift run annotate-t3 serve --project <project-id> --root /absolute/source/checkout --node /absolute/node
```

Approve the printed sign-in URL in T3. The adapter restricts catalogs and every
route to the configured project even if OAuth authorizes broader access. Credentials
stay owner-only in `~/Library/Application Support/AnnotateKit/`, outside the mirror.
They never reach the phone. `--credentials` overrides the private OAuth file path.
Reapprove expired/revoked access with `login`. Ambiguous sends under a changed grant
are retained for reconciliation, never blindly resent as new messages.

Opt into confirmed-delivery cleanup with `clearsT3DeliveredFeedback: true`. The Mac
uses the existing T3 protocol-2 client API to upload a complete ZIP plus up to seven
annotated-image previews, then enqueue them using stable command/message IDs.
The matching installed T3 CLI issues a separate, owner-only orchestration read/operate
token after OAuth authorization is checked. T3 Code itself is unchanged; no fork is
required. The ZIP limit is 50 MiB and each preview limit is 10 MiB. Missing capabilities,
failed uploads, and ambiguous responses preserve the batch.

Only after T3 durably accepts the queued or opening message does the Mac write a content-free
receipt and clear its bundle, archive, staging copies, and per-batch upload state.
The phone processes the receipt while active; hosts can also call
`await Annotate.clearDeliveredFeedback(in: outputDirectory)` on launch/foreground
without installing the overlay. An active canvas remains until closed; unsent notes
are preserved. Minimal receipts and routing IDs remain for retries. T3 keeps its own
conversation/attachment copies according to its lifecycle. Agents reply in T3.
Pending opening-message launch arguments temporarily contain feedback for exact
retries; confirmed cleanup scrubs that content and matching atomic-write remnants.
Generic prompts distinguish Fix changes from Question explanations and use portable
artifact paths inside the attached ZIP.

Offline batches reach the Mac over the paired developer connection. “Sent”
means delivered, not agent completion. This confirmation lasts six seconds and clears
on closing the overlay; completed receipts are not replayed on reopen or launch.
In T3 mode the notes list uses Current, Sending, Sent, and Failed. Confirmed notes
remain in Sent as text-only, in-memory history until the app exits, including after
closing and reopening the overlay. Screenshot files are still cleared on delivery;
completed note history is never restored on relaunch. Pending Sends still resume
delivery tracking. A missing cleanup option keeps legacy
reference-only delivery: messages reference absolute Mac bundle paths, so those files
must remain until explicit cleanup. New and legacy sessions remain schema 1 through
optional routing, catalog-capability, and receipt fields. Routed batches are excluded
from automatic pruning. Legacy Homebrew consumers must stay on `.annotate/sessions`,
never the routed inbox. Closing the app forgets the current destination while
preserving pending batches. Retiring the integration requires revoking both its
OAuth connection and its separately labeled local host session.

Run `node --test Tests/AnnotateT3Tests/*.test.mjs` and `swift test` for transport,
cleanup, device-receipt, and compatibility coverage. Tests do not contact live T3.

Tell your agent:

> Set up AnnotateKit from github.com/ooolzhas/annotatekit in this app.

The [`annotate-setup` skill](skills/annotate-setup/SKILL.md) handles Xcode projects, XcodeGen,
Tuist, SwiftPM, React Native and Expo. In Claude Code, one plugin brings the skill, the MCP server and the CLI:

```
/plugin install annotate --marketplace ooolzhas/annotatekit
```

<details>
<summary>By hand</summary>

Add `https://github.com/ooolzhas/annotatekit` with Swift Package Manager and link **AnnotateKit**
to your app target.

```swift
import AnnotateKit

@main
struct MyApp: App {
    init() { Annotate.install() }   // no-op in Release
    var body: some Scene { WindowGroup { ContentView() } }
}
```

Add `.annotate/` to your `.gitignore`, then install the CLI (not needed with the Claude plugin):

```sh
brew install ooolzhas/tap/annotate   # or: npm install -g annotate-ios · mint install ooolzhas/annotatekit
```
</details>

## React Native and Expo

iOS only. The `annotate-ios` npm package carries the pod, and autolinking picks it up.

```sh
npm install -D annotate-ios
```

**Expo:** add the plugin to `app.json`, then run a development build (`npx expo run:ios` or
`expo-dev-client`). Expo Go can't load native code.

```json
{ "expo": { "plugins": ["annotate-ios"] } }
```

**Bare React Native:** add two lines to `ios/<App>/AppDelegate`, then `cd ios && pod install`.

```swift
import AnnotateKit                // Swift (RN 0.77+), at the top
Annotate.install()                // first line of application(_:didFinishLaunchingWithOptions:)
```

```objc
#import "AnnotateKit-Swift.h"                  // Obj-C (AppDelegate.mm), with the imports
[AnnotateBridge installWithFile:@__FILE__];    // first line of application:didFinishLaunchingWithOptions:
```

The app's iOS deployment target must be 17.0 or later (Expo: `ios.deploymentTarget` in
`expo-build-properties`). The `annotate` CLI works the same as for native apps.

## Usage

The review toolbar's **Drag mode** button switches between **Draw** and **Scroll**. It keeps one hand icon in a fixed material circle above the native tab bar; blue indicates Scroll.
Each opening starts in Draw mode, including after closing with X and shaking to reopen.
Scroll mode always shows the connection indicator or current delivery status above
the toolbar, including before Send. Draw hides the line while delivery tracking continues.

The screen-edge glow and bottom wash ease in together over 0.3 seconds at 75% intensity when review opens and keep animating while scrolling. Scroll mode has no instructional hint; delivery updates still appear.
In Scroll mode, swipes scroll the real app while taps and holds still create annotations; tapping
does not activate the app's buttons. A note freezes its current screen while you write, then saving
returns to live scrolling. Existing notes retain their original captures and remain available in My Notes.
The toolbar's **X** closes annotation mode and keeps unsent notes. Closing reverses the entrance: the toolbar, edge glow, and bottom wash enter and exit together with one 0.3-second ease-in-out. Explicit layer ordering keeps the glow above the frozen screenshot throughout closing. The departing toolbar retains its active docking position through the fade. Reduce Motion uses fades without the toolbar movement. Hosts with no launcher keep the overlay window visible through that exit, returning touches and keyboard ownership immediately. Hosts that invoke review through a shake responder can use `AnnotateOptions.onDismiss` to restore focus after the SDK releases its window.

1. Tap **Annotate** to freeze the screen
2. **Draw**, **tap** an element, or **hold** on a spot
3. Add a note, attach an image
4. Tap **↑** to send
5. Follow the agent's progress on the pill

## Connect your agent

| Agent | Setup |
|---|---|
| **Claude Code** (recommended) | `claude --dangerously-load-development-channels plugin:annotate@annotatekit`. Sends arrive in your open session, even while it's idle. |
| **Claude Code, no flags** | Run `/annotate-watch`. |
| **Cursor, Codex, VS Code, any MCP client** | Add `annotate mcp` (below) and ask the agent to *"keep calling annotation_wait"*. |
| **Unattended** | `annotate run` in the project root runs `claude -p` per send. |

[Channels](https://code.claude.com/docs/en/channels) are a Claude Code research preview, which is
why the flag is needed.

<details>
<summary>MCP config</summary>

```jsonc
// Cursor: .cursor/mcp.json
{ "mcpServers": { "annotate": { "command": "annotate", "args": ["mcp"] } } }

// No CLI installed? npx fetches it on first run
{ "mcpServers": { "annotate": { "command": "npx", "args": ["-y", "annotate-ios", "mcp"] } } }

// VS Code: .vscode/mcp.json
{ "servers": { "annotate": { "type": "stdio", "command": "annotate", "args": ["mcp"] } } }
```

```toml
# Codex: ~/.codex/config.toml
[mcp_servers.annotate]
command = "annotate"
args = ["mcp"]
```

Claude Code without the plugin: `claude mcp add annotate --scope project -- annotate mcp`.
</details>

## What agents get

Each note arrives as a specific component to check, not a description to interpret.

- **Screenshots** at 1x (pixel = point), an annotated copy, and a crop per pin
- **Drawings** as images and vectors
- **Coordinates and the element under each pin**, with nearby text to grep for
- **Device metadata**: model, iOS version, size, appearance, Dynamic Type
- **Your notes**, each tagged **Fix** or **Question**

Instead of "the blue button near the bottom is too small", the agent reads
`Button "Get started" at (24, 300, 120×44)` and edits that view directly.

<details>
<summary>Example prompt</summary>

```
UI annotations from the running app: 2 pins on 1 screen. Please make these changes in the code.

Device: iPhone 17 Pro · iOS 26.0 · 402×874 pt @3x · dark · Dynamic Type L
Coordinates are iOS points, origin top-left. Screen images are 1x, so pixel = point.

Screen 1 (402×874 pt) — annotated …/screens/1-annotated.png · clean …/screens/1.png

1. Button "Get started" at (24, 300, 120×44) — tapped (84, 322), 21% across, 37% down
   bigger, tighter
   Nearby text: "Light that follows your day"
   Crop: …/crops/1.png

2. Sketch over Image "Halo Pendant" at (190, 520, 180×140) — center (280, 590), 70% across, 68% down
   make this card a carousel
   Crop: …/crops/2.png

Full detail (all frames, visible text per screen, sketch vectors): …/session.json
```
</details>

## Tracking status

The pill narrates delivery (*received → working → all changes applied*), and each pin's badge turns
into a check when the agent resolves it. Agents report per pin with MCP tools or the CLI:

| MCP tool | CLI | Does |
|---|---|---|
| `annotation_wait` | | Blocks until you send, then returns the notes |
| `get_annotation_session` | | Prompt plus screens and crops as images |
| `annotation_acknowledge` | `annotate ack <id> <pin>` | Shows "Working on note N" |
| `annotation_resolve` | `annotate resolve <id> <pin> "what changed"` | Marks a pin done |
| `annotation_dismiss` | `annotate dismiss <id> <pin> "why not"` | Declines a pin |
| `annotation_ask` | `annotate ask <id> <pin> "question"` | Asks you; you reply from the notes sheet |

The plugin's Stop hook keeps Claude from ending its turn while a send still shows as in progress.

## Gestures

| Action | Gesture |
|---|---|
| Enter annotate mode | **Annotate** pill, `Annotate.start()`, or launch with `ANNOTATE=1` |
| Draw | Drag anywhere |
| Select an element | Tap |
| Pin an exact spot | Hold for half a second |
| Save a note | Type, then **↑** on the card |
| Undo / redo a stroke | The card's undo and redo buttons; **×** discards the note |
| Review notes | Tap the note count on the bar |
| Send | **↑** on the bar |
| Leave annotate mode | **‹** on the bar (your notes are kept) |

To annotate another screen, leave annotate mode, navigate, and come back. One send carries every
screen.

## How it works

- **Selection.** A tap hit-tests UIKit, then walks the accessibility tree (switched on the first
  time you annotate) to find SwiftUI `Text`, `Button` and `Image`. No view tagging needed;
  `.annotatable()` optionally adds the view's `file:line`.
- **Delivery.** The app writes a session bundle to `.annotate/` in your project. On a physical
  device, the running `annotate` process copies it over `devicectl`, with no network permission or
  Info.plist keys. The bundle format is in [SCHEMA.md](SCHEMA.md).
- **Cost.** Nothing in Release and no dependencies. In DEBUG, near-zero until you enter annotate
  mode.

## Limitations

- iOS 17+ only. Frames assume a full-screen window; Stage Manager windows aren't handled.
- No hover highlight: the Simulator doesn't deliver pointer hover to apps.
- Channels are a research preview, so their flags may change.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) and [AGENTS.md](AGENTS.md).

## License

[MIT](LICENSE) · [annotatekit.com](https://annotatekit.com) · [@ooolzhas](https://x.com/ooolzhas)
