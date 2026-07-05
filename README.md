# Clipboard History HUD

Small macOS clipboard history HUD for `Cmd+Shift+V`.

It watches the system clipboard while the process is running, keeps recent text,
URL, file URL, and image entries in SQLite, and opens a floating picker with
`Cmd+Shift+V`. Choose an item with the mouse or keyboard to put it back on the
clipboard.

Image entries are OCR-indexed in the background with Apple's Vision framework,
so text inside copied screenshots/images can be found from the same search box.

## Build

```sh
cd /Users/yuhyeongchan/project/apps/clipboard-history-hud
swift build -c release
```

## Run

```sh
.build/release/clipboard-history-hud
```

Keep the process running. Copy text, an image, or a URL, then press
`Cmd+Shift+V`.

Keyboard controls in the HUD:

- Type in the search field to filter history
- `Up` / `Down`: move selection
- `Return`: copy selected item back to clipboard
- `Esc`: close
- `Cmd+P`: pin or unpin the selected item
- `Delete`: delete the selected item when the search field is not editing text
- `Cmd+Delete`: clear history
- `Cmd+O`: open the selected URL or file
- `Cmd+S`: save the selected image
- `Cmd+M`: copy the selected URL as a Markdown link

Search tokens:

- `type:image`, `type:url`, `type:text`, `type:file`
- `app:Chrome` or `from:Chrome`
- `ocr:invoice`
- `pinned`
- `today`

Row buttons also provide pin, open/save, and delete actions.

## Install As Login Agent

```sh
cd /Users/yuhyeongchan/project/apps/clipboard-history-hud
./install-launch-agent.sh
```

The launch agent runs the release binary at login and writes logs to:

- `/tmp/clipboard-history-hud.out.log`
- `/tmp/clipboard-history-hud.err.log`

## Uninstall

```sh
launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.local.clipboard-history-hud.plist"
rm "$HOME/Library/LaunchAgents/com.local.clipboard-history-hud.plist"
```

## Privacy

History and OCR text are stored locally in
`~/Library/Application Support/ClipboardHistoryHUD/history.sqlite3`. Existing
`history.json` files are migrated on first launch. By default, image payloads
are persisted only when each image is 3 MB or smaller, up to 30 images and 32 MB
total. Larger or older images still appear as history metadata, but their image
payload is not kept in SQLite.

## Configuration

Optional config file:

```json
{
  "historyLimit": 200,
  "maxPersistedImageBytes": 3145728,
  "maxPersistedImages": 30,
  "maxPersistedImageTotalBytes": 33554432,
  "hotKey": {
    "key": "v",
    "modifiers": ["command", "shift"]
  }
}
```

Save it as:

```text
~/Library/Application Support/ClipboardHistoryHUD/config.json
```

Restart the launch agent after changing the hotkey.
