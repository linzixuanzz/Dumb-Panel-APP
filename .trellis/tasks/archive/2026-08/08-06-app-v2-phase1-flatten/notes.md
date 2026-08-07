# 阶段笔记

## 2026-08-06 · 第一波真机验收通过

commit `0ff0603`，用户在真机上确认「都没有问题」。

验收覆盖：环境页/任务表单的 Autocomplete 浮层、深色模式应用锁模态、
SnackBar 红绿区分、各页滚动到底的留白。

第一波 6 个提交：

```
0ff0603  feat(ui): AppSnack 增加语义 tone，36 处失败提示不再是灰的
70e48e8  fix(theme): primary 不再表示「成功 / 在线 / 已启用」
a838e27  fix(theme): 新增 tintFg 令牌，修 23 处淡底徽章前景读不清
0fb90a0  refactor(ui): 移除全部装饰性投影与 Material elevation
f2aab6c  fix(layout): 没有底部导航栏的页面不再为它留 100dp 死留白
82f6ba4  chore(ui): 删除从未被引用的 ResourceCard 与死配置 navigationBarTheme
```

---

## ★ 本地 `flutter build apk --release` 产出的是**未签名** APK，装不上

出这一波验收包时踩到的，与本期代码改动无关，但会绊倒任何想在本地出包的人。

### 症状

```
apksigner verify --print-certs build/app/outputs/flutter-apk/app-release.apk
  DOES NOT VERIFY
  ERROR: Missing META-INF/MANIFEST.MF
```

APK 的 `META-INF/` 下只有构建元数据（`app-metadata.properties`、
各 androidx 组件的 `.version`），**没有 `MANIFEST.MF` / `*.SF` / `*.RSA`**。

### 根因

`android/app/build.gradle.kts:70-77`：

```kotlin
buildTypes {
    release {
        if (hasReleaseSigning) {
            signingConfig = signingConfigs.getByName("release")
        }
        ...
```

`hasReleaseSigning` 依赖 `android/key.properties` 或 `KEYSTORE_*` 环境变量，
本地都没有 → `signingConfig` 根本不被设置。

**AGP 8+ 在 release buildType 没有 signingConfig 时是直接不签名**，
不像老版本会退回 debug key。所以产物是完全未签名的 APK。

历史构建同样如此（2026-04-23 那个 `app-release.apk` 验证结果一致），
说明这不是新问题，只是本地从来没人拿它去装。

### 正式发版不受影响

`.github/workflows/release.yml:48-60` 与 `android-build.yml:51-63` 会用
`secrets.ANDROID_KEYSTORE_BASE64` 解码出 `android/app/daidai-release.jks`
并生成 `android/key.properties`，CI 产物是正常签名的。

### 本地要出可安装包的两种做法

1. **临时测试签名**（本次用的）：`keytool -genkeypair` 生成 jks 放到**仓库外**，
   再 `apksigner sign --ks <jks> --out <签好的> <未签的>`。
   注意这样签出来的包与正式版**签名不同**，装之前必须卸载旧版，
   本地数据（服务器地址、登录态、应用锁设置）会丢。
2. **用正式 keystore**：把 `key.properties` 放到 `android/` 下。
   该文件与 `.jks` **绝不能进 Git**。

### 已知可改进（未做）

`build.gradle.kts` 可以在 `hasReleaseSigning` 为 false 时退回
`signingConfigs.getByName("debug")`，这样本地 release 包至少可安装。
但那会让「本地包」和「正式包」在没有明显提示的情况下签名不同，
是否值得需要决定，本期未动。

---

## 待办：spec 更新

`spec/frontend/quality-guidelines.md` 的「构建与工具链注意」一节
目前只写了 Flutter SDK 路径含空格的问题，应补上上面这条签名陷阱。
第二波结束时一并更新。
