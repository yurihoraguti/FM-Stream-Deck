# Code signing policy

Free code signing provided by [SignPath.io](https://about.signpath.io/), certificate by [SignPath Foundation](https://signpath.org/).

> Status: the application to the SignPath Foundation open source program is pending. Releases are unsigned until it is approved; this page will be updated when signed builds start.

## What is signed

Only `FMStreamDeck.exe`, built from the source code in this repository by the [GitHub Actions workflow](.github/workflows/build.yml) on tagged releases (`v*`). No third-party binaries are signed.

## Team roles

| Role | Members |
|---|---|
| Committers and reviewers | [@yurihoraguti](https://github.com/yurihoraguti) |
| Approvers | [@yurihoraguti](https://github.com/yurihoraguti) |

- **Committers** may change the source code without further review.
- **Reviewers** review every contribution from non-committers (pull requests) before it is merged.
- **Approvers** manually approve each signing request; every release is approved individually.

All team members use multi-factor authentication for GitHub and SignPath.

## Privacy policy

This program will not transfer any information to other networked systems unless specifically requested by the user or the person installing or operating it.

Details:

- The web server only listens on your local network. It serves the deck page and talks to OBS Studio on your own PC.
- The deck connects only to the OBS WebSocket address you configure.
- If **you** enable a chat source, the deck connects to that service: Twitch chat (`irc-ws.chat.twitch.tv`, anonymous read-only, plus emote images from `static-cdn.jtvnw.net`), YouTube live chat, or the URL you provide. Those services' own privacy policies apply.
- There is no telemetry, analytics, or account. Settings are stored only in the browser of each device (`localStorage`).

## System changes and uninstallation

- With your confirmation and a Windows administrator (UAC) prompt, the server can add two inbound Windows Firewall rules, limited to your local subnet: `FM-Stream Deck - pagina (TCP 8080)` and `FM-Stream Deck - OBS WebSocket (TCP 4455)`.
- To remove them, click **Remover regras** in the management panel, or run `"FM-Stream Deck.bat" -RemoveFirewall` (or `FMStreamDeck.exe --remove-firewall`).
- Nothing is installed. To uninstall, remove the firewall rules as above and delete the folder.
