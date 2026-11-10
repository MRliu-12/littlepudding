# 小布丁 LittlePudding

> 一个「只提醒、不捣乱」的 Windows 变更哨兵：**任何软件在你没明显允许的情况下偷偷改系统，都会留下痕迹并要求你显式批准。**

## 声明

1. **它做什么**：对系统关键位置做快照，之后周期性比对；发现变化就写报告、记录日志；你可以逐条「批准」或忽略。批准 = 你明显允许。
2. **它不做什么**：不拦截内核驱动、不阻止正常安装、不修改任何软件本体、不联网、不收集遥测、不上传任何数据。所有数据只存在本机 `state/` 和 `reports/`。
3. **默认只提醒**：`check` 永远不会自动删改东西。只有显式加 `-Enforce` 才会对「自启动项」尝试回滚——而且失败只记日志，不会让系统更糟。
4. **能力边界**：用户态工具无法 100% 阻止有管理员权限的软件。它能做的是让改动**可见、可追溯、可批准**，并给出第一道防线；真正的强制拦截需要驱动，本项目刻意不做。
5. **免责**：本工具按「现状」提供，不承担因使用或误用造成的任何损失。请先 `init` 看报告、理解行为后再装计划任务。

## 保护范围（监控的快照区域）

| 类别 | 内容 | 风险判定 |
|---|---|---|
| `run` | HKLM/HKCU 的 Run / RunOnce 自启动值 | 新增即高风险 |
| `winlogon` | Userinit / Shell 登录劫持 | 修改即高风险 |
| `services` | 系统服务列表（名称/路径/启动方式） | 新增服务/改路径高风险 |
| `tasks` | 计划任务（名称/作者/动作） | 新增高权限任务高风险 |
| `startup` | 用户与公共「启动」文件夹内的文件 | 新增高风险 |
| `assoc` | 常见扩展名的默认打开应用（UserChoice / HKCR） | 被改低风险，但记录 |
| `hosts` | `%WINDIR%\System32\drivers\etc\hosts` 内容哈希 | 变更高风险 |
| `defender` | Defender 排除路径（如果可用） | 新增排除高风险 |

## 用法

```powershell
# 1) 建立基线（第一次运行）
powershell -ExecutionPolicy Bypass -File .\LittlePudding.ps1 -Action init

# 2) 检查（可放进计划任务，每 30 分钟一次）
powershell -ExecutionPolicy Bypass -File .\LittlePudding.ps1 -Action check

# 3) 查看报告
notepad .\reports\<时间>.md

# 4) 批准某条变化（= 你明显允许）
powershell -ExecutionPolicy Bypass -File .\LittlePudding.ps1 -Action approve -Id <变化ID>

# 5) 安装/卸载计划任务（每 30 分钟检查一次）
powershell -ExecutionPolicy Bypass -File .\LittlePudding.ps1 -Action install
powershell -ExecutionPolicy Bypass -File .\LittlePudding.ps1 -Action uninstall

# 6) 只在自启动项上尝试回滚（默认关闭；需管理员权限才有效）
powershell -ExecutionPolicy Bypass -File .\LittlePudding.ps1 -Action check -Enforce
```

## 「明显允许」的定义

- 明确的用户动作：运行 `approve` 批准某条变化
- 明确的用户动作：安装软件时你亲自确认过安装程序
- 不存在的「明显允许」：静默安装、捆绑安装、更新时顺手勾选、软件自动创建的服务/自启动/关联/排除项

被批准的变化写入 `state/allowlist.json`，以后不再重复提醒；所有批准动作写入 `state/journal.jsonl`，带时间戳。

## 技术实现

- Windows PowerShell 5.1 即可运行（无需安装任何东西）
- 快照存 `state/baseline.json`（JSON）
- 报告存 `reports/YYYYMMDD-HHMMSS.md`，含每条变化的 ID、类别、前值/后值
- 变更 ID = SHA1(类别|键|新值) 前 12 位，便于 `approve`
- 所有脚本注释与代码为 ASCII，用户可见文案为中文

## 目录结构

```
LittlePudding.ps1   主程序（init / check / approve / install / uninstall）
README.md           本文件
LICENSE             MIT
state/              baseline.json / allowlist.json / journal.jsonl（运行时生成）
reports/            检查报告（运行时生成）
```

## 路线图（欢迎 PR）

- [ ] 回滚更多类别（hosts 恢复、文件关联恢复）
- [ ] 托盘常驻 + 气泡提醒
- [ ] 变更分类白名单模板
- [ ] Windows 事件日志审计接入

## License

MIT © 2026 liu990
