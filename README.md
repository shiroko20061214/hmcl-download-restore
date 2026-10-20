# HMCL 下载功能恢复工具

把 HMCL 的「下载」页面恢复回来。

**不改二进制、不打补丁**。做法：换回最后一个还没被加锁的官方版本 **3.17.0.361**，并关掉自动更新提示。

---

## 快速开始

双击 `HMCL-Download-Restore.bat`，放在 HMCL 目录里运行，或：

```bat
HMCL-Download-Restore.bat -HmclDir "D:\HMCL"
HMCL-Download-Restore.bat -Proxy "https://hk.gh-proxy.com/"
HMCL-Download-Restore.bat -Restore
```

PowerShell 用户可直接跑源码：

```powershell
.\Restore-HMCLDownload.ps1 -HmclDir "D:\HMCL"
```

要求：Windows 10/11 自带的 Windows PowerShell 5.1。

---

## 实现原理

### 1. HMCL 的锁和 PCL 不是一回事

| | PCL 2.99 | HMCL 3.17.0.362+ |
|---|---|---|
| 阻止方式 | 编译期常量，代码被删 | 运行时读 IP 判定 |
| 页面表现 | 换成拦截提示 | 原页面 `setDisable(true)` + 警告条 |
| 能否改配置解决 | 不能 | 换 IP 或换版本都可以 |

PCL 用的是 `Public Const RestrictMcDownload As Boolean = True`，被内联进调用点，二进制里连符号都不剩，只能换版本。

HMCL 用的是一个运行时检查 —— 代码原封不动，只是被地区条件挡住。

### 2. 它怎么判断「在中国大陆」

`RegionUtils`（提交 `583e004d`，2026-10-20 08:37 合入）：

```java
private static boolean checkChinaMainlandNetwork() {
    IpWhoIsResponse result = JsonUtils.fromNonNullJson(
        NetworkUtils.doGet("https://ipwho.is"), IpWhoIsResponse.class);
    return !result.success || "CN".equalsIgnoreCase(result.country_code);
}
```

判定结果被缓存在一个 `volatile Boolean` 里，`Launcher` 启动时异步初始化。

**注意这是 fail-closed**：请求失败也算「在中国大陆」。

> ⚠️ 所以**不要试图屏蔽 `ipwho.is`**。屏蔽之后请求失败 → 依然判定为大陆 → 照样锁死，而且更难恢复。这一点和直觉相反。

### 3. 哪个版本还没被加锁

不用猜，查源码树即可：

```powershell
# 有 RegionUtils 就是已加锁
GET /repos/HMCL-dev/HMCL/contents/HMCL/src/main/java/org/jackhuang/hmcl/util/RegionUtils.java?ref=<tag>
```

实测：

| 版本 | 发布日期 | 有 `RegionUtils` | 下载 |
|---|---|---|---|
| 3.17.0.361 | 2026-10-19 | 否 | ✅ |
| **3.17.0.362** | 2026-10-20 08:50 | **是** | ❌（大陆网络） |

`583e004d` 合入于 08:37，362 发布于 08:50 —— 所以 **361 是最后一个干净的正式版**。

### 4. 抑制更新

配置键：

```json
"disableAutoShowUpdateDialog": true
```

位置（3.16 之后）：

```
<HMCL 目录>\.hmcl\config\launcher-settings.json
```

两个容易踩的坑：

- **不要写 `hmcl.json`**。3.16 起它只是「遗留文件」，仅用于一次性迁移，写了基本无效。
- **是合并不是覆盖**。脚本会先备份原文件，用 JSON 解析后只增改这一个键，其余设置原样保留。

另外 HMCL 的「用户数据」（账号、皮肤、Java 缓存）在另一个位置：

```
%APPDATA%\.hmcl\        （Windows；可用 HMCL_USER_HOME 覆盖）
```

脚本**完全不碰**这里。

### 5. 下载源

按实测速度排序，前一个失败自动换下一个：

| 顺序 | 源 | 实测 |
|---|---|---|
| 1 | `hmcl.glavo.site`（HMCL 官方 CDN） | 0.3 s |
| 2 | GitHub Release | 1.6 s |
| 3 | `hk.gh-proxy.com` | 2.2 s |

三者返回同一份字节，且都过 SHA-256 校验：

```
HMCL-3.17.0.361.exe  SHA-256  67308A1FB935F5520A43C42EFCDDE42AB392A6757EBB838EEFFC85D54FB34A5F
HMCL-3.17.0.361.jar  SHA-256  DBB33BF99EFEE104E3432D3F5FD335275E38C38E17B2D75AE07C5214F8EF5E8B
```

这两个值来自官方 Release 页，脚本按它校验后再落盘。**因此 `-Proxy` 用第三方加速前缀也是安全的**。

### 6. 快捷方式

替换后文件名会变（`HMCL-3.16.3.exe` → `HMCL-3.17.0.361.exe`），旧快捷方式会失效。

脚本会扫描：

- 桌面 / 公共桌面
- 开始菜单（当前用户 + 所有用户）
- 任务栏固定项

把指向旧文件的 `.lnk` 改指向新文件；一个都没找到时，在桌面新建一个 `HMCL.lnk`。`-Restore` 时会反向改回去。

不想动快捷方式就加 `-NoShortcut`。

---

## 数据安全边界

脚本只修改两处：

```
<HMCL 目录>\HMCL-<旧版本>.exe        → 备份后替换为 HMCL-3.17.0.361.exe
<HMCL 目录>\.hmcl\config\launcher-settings.json → 增加一个布尔值
```

以下内容**只读不写**：

| 数据 | 说明 |
|---|---|
| 游戏目录（`.minecraft`） | 版本、模组、整合包、存档、资源包、光影 |
| 账号 / 皮肤 | `%APPDATA%\.hmcl` |
| 实例与游戏设置 | `config\game-settings.json`、`config\game-directories.json` |

而且脚本不假设游戏目录在哪 —— 它直接从 HMCL 自己的配置里读：

- `<HMCL 目录>\.hmcl\config\game-directories.json`（便携配置，相对路径）
- `%APPDATA%\.hmcl\config\user-game-directories.json`（全局配置，绝对路径）

跑之前和跑之后各打一次「配置目录指纹 + 各游戏目录的版本/模组/存档数量」，供你对照。指纹一致会明确打印：

```
数据指纹一致（E2118B59A69216E3），游戏目录与配置未被改动。
```

> 所以即使你的 HMCL 和别的启动器共用同一个 `.minecraft`（比如为了省空间），也完全没问题 —— 脚本只是把它列出来，不会写它。

---

## 项目结构

```
.
├── Restore-HMCLDownload.ps1       # 主逻辑（可读源码）
├── build.ps1                      # 打包成单文件 .bat
├── dist/
│   └── HMCL-Download-Restore.bat  # 发布用成品
├── README.md
└── LICENSE
```

`.bat` 的原理：头部是纯 ASCII 批处理，把自身内嵌的 PowerShell 负载释放到临时目录（UTF-8 带 BOM）后执行，退出即删。批处理部分刻意不含非 ASCII 字符，否则 cmd 按 ANSI 读取会破坏控制流。

---

## 常见问题

**Q：为什么不直接改 HMCL 的代码把判定去掉？**

可以，但没必要。HMCL 是 Java + JavaFX，改完要重新编译打包；而且旧版官方二进制本来就是干净的，直接用更省事，也更容易让别人复核。

**Q：用代理/加速器是不是就不会被锁？**

判定看的是出口 IP，如果出口不在中国大陆就不会触发。但这属于网络环境问题，不是本工具的职责，也不建议把它做成工具 —— 每个人情况不同。

**Q：降级会不会丢东西？**

不会。脚本只替换启动器主程序 + 改一个配置布尔值，游戏数据、账号、实例设置都不动，且运行前后会打指纹给你对照。

**Q：会被 HMCL 自动更新升回去吗？**

不会自动替换。脚本已写入 `disableAutoShowUpdateDialog`，启动时不会再弹更新窗。

**Q：以后 3.17.0.361 也不行了怎么办？**

改 `Restore-HMCLDownload.ps1` 顶部的 `$Pin`（版本号 + 两个哈希），并用第 3 节的方法确认目标版本没有 `RegionUtils`。

**Q：`-Restore` 恢复的是什么？**

最近一次备份的主程序。备份名形如 `HMCL-3.16.3.exe.bak-3.16.3`，可手动清理。

---

## 免责声明

本项目仅对本地已安装软件做版本回退与配置修改，不修改任何二进制内容，不绕过任何技术保护措施。是否使用由你自行判断并承担相应风险。

HMCL 是 [HMCL-dev/HMCL](https://github.com/HMCL-dev/HMCL) 的作品，请遵守其许可协议。

## 许可

MIT
