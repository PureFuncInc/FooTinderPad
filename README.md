# FooTinderPad

將遊戲控制器 (Game Controller) 對應為 macOS 的鍵盤與滑鼠輸入, 讓你能用搖桿操作整個系統。

## Requirements

- macOS 13 (Ventura) 以上
- Swift 5.9 以上 (Xcode 15+)
- 已配對的遊戲控制器 (Xbox / PlayStation)
- 系統設定中授予 「輔助使用 (Accessibility)」 權限

## Install

```bash
make clean && make install
```

## 預設設定

![控制器正面](docs/front.png)
![控制器背面](docs/back.png)

```json
{
  "deadzone": 0.15,
  "mouseSpeed": 15,
  "scrollSpeed": 2,
  "leftStick": "mouse",
  "rightStick": "scroll",
  "bindings": {
    "buttonA": { "type": "key", "key": "Space", "repeat": true },
    "buttonB": { "type": "key", "key": "Return" },
    "buttonX": { "type": "mouseButton", "button": "left" },
    "buttonY": { "type": "key", "key": "Backspace", "repeat": true },
    "leftShoulder": { "type": "key", "key": "Escape" },
    "rightShoulder": { "type": "mouseButton", "button": "right" },
    "leftTrigger": { "type": "key", "key": "RightShift" },
    "rightTrigger": { "type": "key", "key": "Alt+Return" },
    "leftThumbstickButton": { "type": "key", "key": "Cmd+C" },
    "rightThumbstickButton": { "type": "key", "key": "Cmd+V" },
    "dpadUp": { "type": "key", "key": "Up", "repeat": true },
    "dpadDown": { "type": "key", "key": "Down", "repeat": true },
    "dpadLeft": { "type": "key", "key": "Left", "repeat": true },
    "dpadRight": { "type": "key", "key": "Right", "repeat": true },
    "createButton": { "type": "key", "key": "Fn+Ctrl+Left" },
    "optionsButton": { "type": "key", "key": "Fn+Ctrl+Right" }
  }
}
```

## PS5 示範設定 (易上手版)

下載: [`docs/examples/easy-preset.json`](docs/examples/easy-preset.json) — 直接覆蓋到 `~/Library/Application Support/FooTinderPad/config.json` 即可。

設計重點: 善用 PS 慣例 (Cross 確認 / Circle 取消)、讓三角 / 方塊 / 觸控板邊上的小鈕都各司其職、L2/R2 直接給最常用的複製貼上。

| 按鈕 | 對應 | 說明 |
|---|---|---|
| 左搖桿 | 滑鼠移動 | `mouseSpeed: 25` |
| 右搖桿 | 滾輪捲動 | `scrollSpeed: 5` |
| × Cross | 滑鼠左鍵 | PS 慣例「主要動作」 |
| ○ Circle | Escape | PS 慣例「取消/返回」 |
| ■ Square | Backspace (repeat) | 文字編輯刪除, 按住連續刪 |
| △ Triangle | Space | 影片播放 / 瀏覽器捲頁 |
| L1 | LeftShift | 跟方向鍵搭配選文字, 也跟 R1 (Return) 搭配組成 Shift+Enter |
| R1 | Return | 確認 / 換行 |
| L2 | LeftCmd | 按住搭配實體鍵盤組合 Cmd 快捷鍵 |
| R2 | RightCmd | 同上, 食指搆得到的位置, 適合右手切換 app |
| L3 | Cmd+Z | Undo |
| R3 | 滑鼠右鍵 | Context menu |
| D-pad ↑↓←→ | 滑鼠微移動 | `dpad: "mouse"`, `dpadMouseSpeed: 3`, 使用原始碼內建線性曲線 |
| Create (左上小鈕) | Cmd+V | 貼上 |
| Options (右上小鈕) | Cmd+C | 複製 (拇指容易按到, 比扳機順) |
| 觸控板按下 | Fn+Ctrl+Up | 呼叫 Mission Control (macOS 內建快捷鍵, 不需額外設定) |

## Launch at Login

從選單列點 FooTinderPad 圖示 → `Launch at Login` 切換開關。打開後 macOS 會在使用者登入時自動啟動 app, 同樣的開關也會出現在「系統設定 → 一般 → 登入項目」。

第一次開啟時 macOS 可能要求核可: 選單上的項目會旁邊出現黃色三角警示, 點下去會帶你到「系統設定 → 一般 → 登入項目」, 在那邊把 FooTinderPad 切到開即可。

若 app 是用本機 self-signed 簽章 (例如預設的 `FooTinderPadDev` cert, 沒有 Apple Developer Team Identifier), `SMAppService` 沒辦法登錄 login item。這時我們會自動 fallback: 寫一份 LaunchAgent plist 到 `~/Library/LaunchAgents/com.purefuncinc.FooTinderPad.plist`, 下次登入由 launchd 啟動 app。要關掉一樣從選單按一次 `Launch at Login` 即可 (我們會把 plist 刪掉)。注意這條路線下,「系統設定 → 一般 → 登入項目」清單不會列出 FooTinderPad — 我們選單上的 toggle 是真實狀態。

## 支援的控制器按鈕

下表的 key 用於 `bindings` 物件的 JSON 屬性名。沒列在 config 裡的按鈕會被當成 `none`。

| key | PlayStation | Xbox | 說明 |
|---|---|---|---|
| `buttonA` | × Cross | A | 下方面鈕 |
| `buttonB` | ○ Circle | B | 右方面鈕 |
| `buttonX` | ■ Square | X | 左方面鈕 |
| `buttonY` | △ Triangle | Y | 上方面鈕 |
| `leftShoulder` / `rightShoulder` | L1 / R1 | LB / RB | 上肩鍵 |
| `leftTrigger` / `rightTrigger` | L2 / R2 | LT / RT | 下扳機 (類比, 觸發點 0.55 / 釋放點 0.45) |
| `leftThumbstickButton` / `rightThumbstickButton` | L3 / R3 | LS / RS | 按下搖桿 |
| `dpadUp` / `dpadDown` / `dpadLeft` / `dpadRight` | 方向鍵 | 方向鍵 | |
| `createButton` | Create (左上小鈕) | View | 觸控板左上方 |
| `optionsButton` | Options (右上小鈕) | Menu | 觸控板右上方 |
| `touchpadButton` | 按下整片觸控板 | — | 僅 PS4 (DualShock4) / PS5 (DualSense) 有, Xbox 無此鈕 |

`leftStick` / `rightStick` 屬性接受 `"mouse"`、 `"scroll"`、 `"none"` 三種角色。

搖桿與 D-pad 的移動曲線寫在原始碼中, 不從 JSON config 調整。`dpad` 屬性接受 `"bindings"`、 `"mouse"`、 `"scroll"`、 `"none"` 四種角色。
預設設定使用 `"mouse"` 做線性滑鼠微移動；若想恢復方向鍵綁定, 設為 `"bindings"` 並在 `bindings` 裡加入 `dpadUp` / `dpadDown` / `dpadLeft` / `dpadRight`。

```json
{
  "deadzone": 0.15,
  "mouseSpeed": 64,
  "scrollSpeed": 2,
  "leftStick": "mouse",
  "rightStick": "scroll",
  "dpad": "mouse",
  "dpadMouseSpeed": 4,
  "dpadScrollSpeed": 2,
  "bindings": {
    "buttonA": { "type": "key", "key": "Space", "repeat": true },
    "buttonB": { "type": "key", "key": "Return" },
    "buttonX": { "type": "mouseButton", "button": "left" },
    "buttonY": { "type": "key", "key": "Backspace", "repeat": true },
    "leftShoulder": { "type": "key", "key": "Escape" },
    "rightShoulder": { "type": "mouseButton", "button": "right" },
    "leftTrigger": { "type": "key", "key": "RightShift" },
    "rightTrigger": { "type": "key", "key": "Alt+Return" },
    "leftThumbstickButton": { "type": "key", "key": "Cmd+C" },
    "rightThumbstickButton": { "type": "key", "key": "Cmd+V" },
    "createButton": { "type": "key", "key": "Fn+Ctrl+Left" },
    "optionsButton": { "type": "key", "key": "Fn+Ctrl+Right" }
  }
}
```

## 支援的按鍵

`bindings` 中使用的 key 字串 (例如 `"key": "Ctrl+Shift+A"`) 由 `KeyParser` 解析。Token 大小寫不敏感, 以 `+` 串接組合鍵。

### 修飾鍵 (Modifiers)

| 修飾鍵 | 可用別名 |
|---|---|
| Control | `ctrl`, `control`, `leftctrl`, `leftcontrol`, `rightctrl`, `rightcontrol` |
| Option / Alt | `alt`, `option`, `opt`, `leftalt`, `leftoption`, `rightalt`, `rightoption` |
| Shift | `shift`, `leftshift`, `rightshift` |
| Command / Win | `cmd`, `command`, `win`, `leftcmd`, `leftcommand`, `leftwin`, `rightcmd`, `rightcommand`, `rightwin` |
| Function | `fn` |

### 主鍵 (Main keys)

- **字母**: `a`–`z` (單字元)
- **數字**: `0`–`9`
- **功能鍵**: `f1`–`f20`
- **方向鍵**: `up`, `down`, `left`, `right`
- **編輯 / 導覽**: `space`, `return`, `tab`, `escape`, `backspace` (macOS Delete) 、 `delete` (Forward Delete) 、 `home`, `end`, `pageup`, `pagedown`
- **符號鍵**: `minus`, `equal`, `leftbracket`, `rightbracket`, `backslash`, `semicolon`, `quote`, `comma`, `period`, `slash`, `grave`

### 組合規則

- 單一 token 可以是「主鍵」 (例: `a`, `space`) 或「純修飾鍵綁定」 (例: `ctrl`, `fn`) 。
- 多 token 時, 最後一個必須是主鍵, 前面全部必須是修飾鍵, 例如 `Ctrl+Shift+A`、 `Cmd+Space`、 `Alt+Return`。
- 重複的修飾鍵會自動去重。
- 結尾若是修飾鍵 (例: `Ctrl+Shift`) 會丟出 `modifierInMainKeyPosition` 錯誤。
- 空 token (開頭、 結尾或連續的 `+`) 會丟出 `emptySeparatorComponent` 錯誤。

### 自動重複 (auto-repeat)

`.key` 類型的 binding 可以加 `"repeat": true`,按住按鈕時對應鍵會以 ~30 Hz 連續重發 (400 ms 初始延遲後),類似實體鍵盤按住 Backspace 連刪。預設為 `false`,寫了 `"repeat": true` 但綁定是純修飾鍵 / mouseButton / none 的話會被忽略並產生 warning。

範例:

```json
"buttonX": { "type": "key", "key": "Backspace", "repeat": true }
```
