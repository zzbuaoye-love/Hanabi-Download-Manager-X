# UI 扩展

插件可以通过 `ui_extensions` 声明设置页、侧边栏和插件页面。控件由 Hanabi 渲染，插件不能注入 Flutter 代码。

## 挂载点

| 挂载点 | 说明 |
| --- | --- |
| `settings` | 插件管理页中的设置对话框。 |
| `sidebar` | 插件启用后出现的独立侧边栏页面。 |
| `pages` | 具名插件页面：独立的侧边栏入口，或替换白名单内的内置页面。 |

## 设置页示例

```json
{
  "ui_extensions": {
    "settings": [
      {
        "type": "switch",
        "id": "auto_catch",
        "label": "自动接管",
        "description": "自动处理支持的下载链接。",
        "default": true,
        "icon": "fluent:settings"
      },
      {
        "type": "text_input",
        "id": "endpoint",
        "label": "服务地址",
        "placeholder": "http://127.0.0.1:6800"
      },
      {
        "type": "slider",
        "id": "connections",
        "label": "最大连接数",
        "min": 1,
        "max": 16,
        "divisions": 15,
        "default": 8
      },
      {
        "type": "dropdown",
        "id": "profile",
        "label": "下载策略",
        "default": "balanced",
        "options": [
          {"label": "节能", "value": "eco"},
          {"label": "均衡", "value": "balanced"},
          {"label": "性能", "value": "performance"}
        ]
      },
      {
        "type": "button",
        "id": "test_connection",
        "label": "测试连接",
        "action": "plugin.connection.test"
      }
    ]
  }
}
```

## 侧边栏示例

数组写法使用默认的底部位置：

```json
{
  "ui_extensions": {
    "sidebar": [
      {
        "type": "text",
        "id": "overview",
        "label": "远程下载",
        "description": "管理远程下载服务。"
      }
    ]
  }
}
```

对象写法可以指定导航位置：

```json
{
  "ui_extensions": {
    "sidebar": {
      "placement": "top",
      "controls": [
        {
          "type": "button",
          "id": "refresh",
          "label": "刷新",
          "action": "plugin.sidebar.refresh"
        }
      ]
    }
  }
}
```

| `placement` | 位置 |
| --- | --- |
| `top` | 下载中、已完成等主导航区域。 |
| `bottom` | 插件、设置、关于等工具区域。默认值。 |

## 插件页面（pages）

`pages` 是页面对象数组。每个页面要么作为独立侧边栏入口出现，要么通过 `replaces` 替换内置页面。

独立页面：

```json
{
  "ui_extensions": {
    "pages": [
      {
        "id": "dashboard",
        "title": "远程面板",
        "icon": "fluent:cloud",
        "placement": "top",
        "provider": "aria2.dashboard.render",
        "refresh_seconds": 10,
        "elements": [
          {"type": "text", "id": "loading", "label": "正在加载…"}
        ]
      }
    ]
  }
}
```

替换内置"已完成"页面：

```json
{
  "ui_extensions": {
    "pages": [
      {
        "id": "history",
        "title": "下载历史",
        "replaces": "completed",
        "provider": "history.page.render"
      }
    ]
  }
}
```

### 页面字段

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `id` | string | 是 | 插件内唯一，格式同插件 ID（小写字母、数字、`._-`）。 |
| `title` | string | 是 | 侧边栏与页面头部标题。 |
| `icon` | string | 否 | `fluent:<name>` 或插件目录内的相对图片路径。 |
| `replaces` | string | 否 | 要替换的内置页面 ID。白名单当前仅 `completed`。 |
| `placement` | string | 否 | 独立页面的侧边栏位置，`top` 或 `bottom`（默认）。替换页面忽略此字段。 |
| `elements` | array | 二选一 | 静态控件列表，同 `sidebar` 控件格式。 |
| `provider` | string | 二选一 | 返回动态控件的插件方法名。`elements` 与 `provider` 至少声明一个。 |
| `refresh_seconds` | integer | 否 | provider 自动刷新间隔。`0`（默认）关闭，或 `5`-`3600` 秒；需要同时声明 `provider`。 |

规则：

- 同一插件内页面 `id` 不能重复，`replaces` 同一内置页面不能声明两次。
- 多个启用的插件替换同一内置页面时，`priority` 最高者生效，其余插件的该页面被忽略。
- 声明了 `provider` 时，`elements` 作为加载中或失败时的回退内容。

### provider 协议

宿主调用 `provider` 指定的方法获取动态内容，`params` 为：

```json
{
  "page": "history",
  "replaces": "completed",
  "state": {"filter": "all"},
  "context": {"completedCount": 3, "completedTasks": [{"id": "…"}]}
}
```

- `replaces` 仅在替换页面时存在。
- `state` 是该页面当前持久化的控件状态。
- `context` 是宿主注入的上下文数据；仅 `replaces: "completed"` 时包含 `completedCount` 与 `completedTasks`（最多 200 条，字段：`id`、`url`、`fileName`、可选 `fileSize`、`filePath`、`endTime`、`averageSpeed`）。其他页面为空对象。

方法必须返回：

```json
{"elements": [{"type": "text", "id": "row1", "label": "示例"}]}
```

`elements` 数组使用与 `sidebar` 相同的控件格式。返回其他形状会显示错误并回退到清单中的静态 `elements`。

页面上的按钮点击时，宿主调用按钮 `action` 指定的方法，`params` 为 `{"page": "<id>", "state": {…}, "context": {…}}`；动作完成后若声明了 `provider`，宿主会自动重新调用它刷新内容。控件状态变化会调用 `onPageStateChanged` 通知（`params` 为 `{"page": "<id>", "state": {…}}`）。页面状态按 `<plugin-id>_page_<page-id>` 命名空间独立持久化。

## 控件类型

| `type` | 用途 | 关键字段 | 状态值 |
| --- | --- | --- | --- |
| `switch` | 布尔设置 | `default` | boolean |
| `text_input` | 单行文本 | `placeholder`、`default` | string |
| `button` | 执行命令 | `action` | 不写入状态 |
| `text` | 标题与说明 | `description` | 不写入状态 |
| `slider` | 数值范围 | `min`、`max`、`divisions` | number |
| `dropdown` | 单选列表 | `options`、`default` | 任意 JSON 标量 |

所有控件都支持：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `id` | string | 同一挂载点内唯一，不能为空。 |
| `label` | string | 用户可见标签，不能为空。 |
| `description` | string | 可选辅助说明。 |
| `default` | any | 首次显示时的默认值。 |
| `icon` | string | Fluent 图标名称，可带 `fluent:` 前缀。 |

## 状态变更方法

用户修改设置页后，宿主会保存完整状态并调用：

```text
onSettingsChanged
```

`params` 是设置页的完整状态对象：

```json
{
  "auto_catch": true,
  "endpoint": "http://127.0.0.1:6800",
  "connections": 8,
  "profile": "balanced"
}
```

侧边栏状态变化调用：

```text
onSidebarStateChanged
```

这两个通知当前为异步触发。宿主已经先保存状态，不会因为插件返回错误而回滚 UI。

## 按钮动作

按钮点击时，宿主调用 `action` 指定的方法，并把当前挂载点的完整状态作为 `params`：

```json
{
  "type": "button",
  "id": "test_connection",
  "label": "测试连接",
  "action": "plugin.connection.test"
}
```

方法名属于插件私有命名空间，建议采用 `<plugin-domain>.<resource>.<verb>` 风格，避免与 `hanabi.*` 宿主保留方法混淆。

当前 UI 不会自动把按钮返回的 `result` 合并到控件状态，也不会直接显示响应消息。需要更新展示时，应写入持久数据并在后续版本的 UI API 中接入；不要依赖未声明行为。

## 状态持久化

- 设置页状态由宿主按插件 ID 保存。
- 侧边栏状态使用独立命名空间保存。
- 插件升级后，同名控件 ID 会继续使用原值。
- 删除控件不会立即清理旧键；插件应忽略未知字段。
- 更改控件 ID 等同于创建新设置项。

## 主题覆盖（实验性）

声明 `theme_provider` 能力后可以提供：

```json
{
  "capabilities": ["theme_provider"],
  "theme_overrides": {
    "colors": {
      "primary": "#22C55E"
    }
  }
}
```

当前仅应用 `colors.primary`。多个启用的主题插件同时存在时，不保证用户可控的冲突顺序，因此一个安装环境中应只启用一个主题提供者。

## 限制

- 不支持任意 HTML、WebView 或 Flutter Widget 注入。
- `settings` 和 `sidebar` 不支持控件条件显示、动态列表或运行时修改 Schema；动态内容仅限 `pages` 的 `provider` 机制。
- 内置页面替换仅限白名单（当前为 `completed`），不支持替换其他页面或注入任意路由。
- 不支持把动作结果自动转换成通知或表单校验错误。

这些限制保证插件 UI 可控、可升级，并与宿主主题和无障碍能力一致。
