# FooTinderPad

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
