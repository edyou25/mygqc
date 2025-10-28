# QGroundControl Linux AppImage 部署流程

## 概述

本文档记录了如何在Linux系统上构建和部署QGroundControl的AppImage包。AppImage是一个独立的可执行文件，包含所有必需的依赖库，可以在大多数Linux发行版上运行。

## 前置条件

### 系统要求
- Ubuntu 20.04 / 22.04 或类似的Linux发行版
- CMake 3.16+
- Qt 5.15.2 (安装在 `/home/hw/Qt/5.15.2/gcc_64/`)
- GCC 9+ / Clang 12+

### 必要工具
```bash
sudo apt-get update
sudo apt-get install -y \
    build-essential \
    cmake \
    git \
    libgstreamer1.0-dev \
    libgstreamer-plugins-base1.0-dev \
    libsdl2-dev \
    libssl-dev \
    libxcb-xinerama0 \
    libxkbcommon-x11-0
```

## 构建流程

### 1. 配置和编译

#### 使用CMake构建
```bash
cd /home/hw/qgroundcontrol
mkdir -p build
cd build

# 配置CMake
cmake .. \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_PREFIX_PATH=/home/hw/Qt/5.15.2/gcc_64

# 编译（使用多核加速）
cmake --build . -j$(nproc)
```

编译完成后，可执行文件位于: `/home/hw/qgroundcontrol/build/QGroundControl`

### 2. 验证编译结果

```bash
# 检查可执行文件
ls -lh /home/hw/qgroundcontrol/build/QGroundControl

# 快速测试（显示版本信息后退出）
./QGroundControl --version
```

## AppImage 打包流程

### 方法一: 使用项目自带脚本 (不推荐 - 依赖系统Qt)

项目提供的打包脚本会生成一个依赖系统Qt库的AppImage，**不适合分发给其他用户**。

```bash
cd /home/hw/qgroundcontrol
bash deploy/create_linux_appimage.sh . build deploy
```

**问题**: 生成的AppImage依赖于本机的Qt安装路径 (`/home/hw/Qt/5.15.2/`), 在其他用户的系统上会失败。

### 方法二: 使用linuxdeployqt (推荐 - 自包含)

使用 `linuxdeployqt` 工具可以生成真正自包含的AppImage，bundled所有Qt库和依赖。

#### 步骤1: 准备AppDir目录结构

```bash
# 创建标准的AppDir结构
APPDIR=/home/hw/tmp/AppDir-QGC
rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/bin" \
         "$APPDIR/usr/share/applications" \
         "$APPDIR/usr/share/icons/hicolor/512x512/apps"

# 复制可执行文件
cp /home/hw/qgroundcontrol/build/QGroundControl "$APPDIR/usr/bin/QGroundControl"

# 复制desktop文件
cp /home/hw/qgroundcontrol/deploy/org.mavlink.qgroundcontrol.desktop \
   "$APPDIR/usr/share/applications/qgroundcontrol.desktop"

# 复制图标
cp /home/hw/qgroundcontrol/resources/icons/qgroundcontrol.png \
   "$APPDIR/usr/share/icons/hicolor/512x512/apps/qgroundcontrol.png"

# 创建qt.conf (可选，linuxdeployqt会自动生成)
cat > "$APPDIR/usr/bin/qt.conf" << 'EOF'
[Paths]
Plugins=plugins
Imports=qml
Qml2Imports=qml
EOF
```

#### 步骤2: 下载linuxdeployqt

```bash
cd /home/hw/tmp
curl -L -o linuxdeployqt.AppImage \
    https://github.com/probonopd/linuxdeployqt/releases/download/continuous/linuxdeployqt-continuous-x86_64.AppImage
chmod +x linuxdeployqt.AppImage
```

#### 步骤3: 运行linuxdeployqt部署Qt依赖

```bash
cd /home/hw/tmp

# 第一步: 部署Qt库和依赖（不生成AppImage）
./linuxdeployqt.AppImage \
    /home/hw/tmp/AppDir-QGC/usr/share/applications/qgroundcontrol.desktop \
    -always-overwrite \
    -bundle-non-qt-libs \
    -qmldir=/home/hw/qgroundcontrol/src \
    -qmake=/home/hw/Qt/5.15.2/gcc_64/bin/qmake \
    -verbose=2
```

这一步会:
- 复制所有需要的Qt库到 `AppDir-QGC/usr/lib/`
- 复制Qt插件 (platforms, mediaservice, audio等)
- 复制QML模块和依赖
- 复制系统库 (GStreamer, ICU, Kerberos等)
- 修改所有库的rpath为 `$ORIGIN` 确保相对路径查找
- 生成翻译文件

#### 步骤4: 生成最终AppImage

```bash
cd /home/hw/tmp

# 第二步: 从部署好的AppDir生成AppImage
ARCH=x86_64 ./linuxdeployqt.AppImage \
    /home/hw/tmp/AppDir-QGC/usr/share/applications/qgroundcontrol.desktop \
    -appimage \
    -qmake=/home/hw/Qt/5.15.2/gcc_64/bin/qmake
```

生成的AppImage位于: `/home/hw/tmp/QGroundControl-x86_64.AppImage`

#### 步骤5: 复制到部署目录

```bash
# 复制到项目的deploy目录
cp /home/hw/tmp/QGroundControl-x86_64.AppImage \
   /home/hw/qgroundcontrol/deploy/QGroundControl-Fixed.AppImage

# 设置执行权限
chmod +x /home/hw/qgroundcontrol/deploy/QGroundControl-Fixed.AppImage
```

### 3. 验证AppImage

#### 本地测试
```bash
# 快速测试（会自动提取和运行）
/home/hw/qgroundcontrol/deploy/QGroundControl-Fixed.AppImage --version

# 或者在不同目录下测试
cd /tmp
/home/hw/qgroundcontrol/deploy/QGroundControl-Fixed.AppImage
```

#### 检查bundled库

```bash
# 提取AppImage内容
cd /home/hw/tmp
/home/hw/qgroundcontrol/deploy/QGroundControl-Fixed.AppImage --appimage-extract

# 检查Qt库是否已bundled
find squashfs-root/usr/lib -name 'libQt5*.so*' | head -n 10

# 使用ldd验证依赖解析
cd squashfs-root
LD_LIBRARY_PATH=usr/lib:$LD_LIBRARY_PATH ldd usr/bin/QGroundControl | grep libQt5 | head -n 5
```

预期结果: 所有Qt库应该指向AppImage内部路径 (`usr/lib/libQt5*.so.5`)

## 常见问题排查

### 问题1: 客户WSL运行报错 "undefined symbol ... version Qt_5"

**原因**: AppImage没有bundled Qt库,依赖系统Qt导致ABI不兼容

**解决方案**: 使用上述"方法二"重新打包,确保Qt库bundled到AppImage内部

**验证方法**:
```bash
# 提取并检查
./your.AppImage --appimage-extract
find squashfs-root -name 'libQt5Core.so*'
# 应该在 squashfs-root/usr/lib/ 下找到Qt库
```

### 问题2: linuxdeployqt报错 "This is not a valid Qt binary"

**原因**: 可执行文件未正确链接Qt

**解决方案**: 
- 检查编译时CMAKE_PREFIX_PATH是否正确指向Qt安装目录
- 重新编译QGroundControl

### 问题3: AppImage在其他系统上无法启动

**可能原因**:
1. 缺少FUSE支持 (老版本Linux)
2. AppImage没有执行权限
3. 缺少必要的系统库 (X11, OpenGL等)

**解决方法**:
```bash
# 方法1: 安装FUSE
sudo apt-get install fuse libfuse2

# 方法2: 使用extract-and-run模式（不需要FUSE）
./QGroundControl-Fixed.AppImage --appimage-extract-and-run

# 方法3: 手动提取并运行
./QGroundControl-Fixed.AppImage --appimage-extract
cd squashfs-root
./AppRun
```

### 问题4: GStreamer插件未找到

**现象**: 视频功能不工作

**解决方案**: 
- 确保linuxdeployqt使用了 `-qmldir` 参数指向src目录
- 手动检查 `usr/lib/gstreamer-1.0/` 插件是否存在

## AppImage内部结构

成功打包的AppImage内部结构:
```
squashfs-root/
├── AppRun                          # 启动脚本
├── QGroundControl                  # 符号链接 -> usr/bin/QGroundControl
├── qgroundcontrol.desktop          # Desktop entry
├── qgroundcontrol.png              # 应用图标
└── usr/
    ├── bin/
    │   ├── QGroundControl          # 主可执行文件
    │   └── qt.conf                 # Qt配置
    ├── lib/
    │   ├── libQt5*.so.5            # 所有Qt库
    │   ├── libicu*.so.*            # ICU库
    │   ├── libgst*.so.*            # GStreamer库
    │   └── ...                     # 其他依赖
    ├── plugins/
    │   ├── platforms/              # Qt平台插件
    │   ├── mediaservice/           # Qt多媒体插件
    │   └── ...
    ├── qml/                        # QML模块
    ├── translations/               # 翻译文件
    └── share/
        ├── applications/
        └── icons/
```

## 与官方AppImage对比

### 官方QGroundControl AppImage (v4.4.4)
- 大小: 182 MB
- Qt库: Bundled在 `Qt/libs/` 目录
- 可在任何Linux发行版运行

### 使用linuxdeployqt生成的AppImage
- 大小: ~127 MB (更小)
- Qt库: Bundled在 `usr/lib/` 目录
- 标准AppDir结构
- 同样可在任何Linux发行版运行

## 自动化脚本

可以创建一个自动化脚本简化打包流程:

```bash
#!/bin/bash
# deploy_appimage.sh

set -e

PROJECT_ROOT="/home/hw/qgroundcontrol"
BUILD_DIR="$PROJECT_ROOT/build"
DEPLOY_DIR="$PROJECT_ROOT/deploy"
TMP_DIR="/home/hw/tmp"
APPDIR="$TMP_DIR/AppDir-QGC"
QT_DIR="/home/hw/Qt/5.15.2/gcc_64"

echo "==> 清理旧文件"
rm -rf "$APPDIR"
rm -f "$TMP_DIR/QGroundControl-x86_64.AppImage"

echo "==> 创建AppDir结构"
mkdir -p "$APPDIR/usr/bin" \
         "$APPDIR/usr/share/applications" \
         "$APPDIR/usr/share/icons/hicolor/512x512/apps"

echo "==> 复制文件"
cp "$BUILD_DIR/QGroundControl" "$APPDIR/usr/bin/"
cp "$DEPLOY_DIR/org.mavlink.qgroundcontrol.desktop" \
   "$APPDIR/usr/share/applications/qgroundcontrol.desktop"
cp "$PROJECT_ROOT/resources/icons/qgroundcontrol.png" \
   "$APPDIR/usr/share/icons/hicolor/512x512/apps/"

echo "==> 下载linuxdeployqt (如果需要)"
cd "$TMP_DIR"
if [ ! -f "linuxdeployqt.AppImage" ]; then
    curl -L -o linuxdeployqt.AppImage \
        https://github.com/probonopd/linuxdeployqt/releases/download/continuous/linuxdeployqt-continuous-x86_64.AppImage
    chmod +x linuxdeployqt.AppImage
fi

echo "==> 部署Qt依赖"
./linuxdeployqt.AppImage \
    "$APPDIR/usr/share/applications/qgroundcontrol.desktop" \
    -always-overwrite \
    -bundle-non-qt-libs \
    -qmldir="$PROJECT_ROOT/src" \
    -qmake="$QT_DIR/bin/qmake" \
    -verbose=1

echo "==> 生成AppImage"
ARCH=x86_64 ./linuxdeployqt.AppImage \
    "$APPDIR/usr/share/applications/qgroundcontrol.desktop" \
    -appimage \
    -qmake="$QT_DIR/bin/qmake"

echo "==> 复制到部署目录"
cp "$TMP_DIR/QGroundControl-x86_64.AppImage" \
   "$DEPLOY_DIR/QGroundControl-Fixed.AppImage"

echo "==> 完成!"
echo "AppImage位置: $DEPLOY_DIR/QGroundControl-Fixed.AppImage"
ls -lh "$DEPLOY_DIR/QGroundControl-Fixed.AppImage"
```

使用方法:
```bash
chmod +x deploy_appimage.sh
./deploy_appimage.sh
```

## 分发给客户

### 文件传输
```bash
# 方法1: 使用scp
scp /home/hw/qgroundcontrol/deploy/QGroundControl-Fixed.AppImage \
    user@customer-machine:/path/to/destination/

# 方法2: 上传到云存储
# (Google Drive, Dropbox, 阿里云OSS等)
```

### 客户使用说明

发给客户的使用说明:

```markdown
# QGroundControl 使用说明

## 安装步骤

1. 下载 `QGroundControl-Fixed.AppImage` 文件

2. 添加执行权限:
   ```bash
   chmod +x QGroundControl-Fixed.AppImage
   ```

3. 运行:
   ```bash
   ./QGroundControl-Fixed.AppImage
   ```

## 可选: 桌面集成

将AppImage添加到应用程序菜单:
```bash
# 复制到本地bin目录
mkdir -p ~/.local/bin
cp QGroundControl-Fixed.AppImage ~/.local/bin/qgroundcontrol

# 创建desktop entry
mkdir -p ~/.local/share/applications
cat > ~/.local/share/applications/qgroundcontrol.desktop << EOF
[Desktop Entry]
Name=QGroundControl
Exec=$HOME/.local/bin/qgroundcontrol
Icon=qgroundcontrol
Type=Application
Categories=Utility;
EOF
```

## 故障排查

如果遇到问题,尝试以下方法:

1. 使用extract-and-run模式:
   ```bash
   ./QGroundControl-Fixed.AppImage --appimage-extract-and-run
   ```

2. 查看详细日志:
   ```bash
   QT_LOGGING_RULES="*=true" ./QGroundControl-Fixed.AppImage
   ```

3. 安装FUSE支持 (某些老系统需要):
   ```bash
   sudo apt-get install fuse libfuse2
   ```
```

## 版本记录

- 2025-10-28: 初始版本，使用linuxdeployqt生成自包含AppImage
- AppImage大小: 127 MB
- Qt版本: 5.15.2
- 支持的架构: x86_64

## 参考资料

- [linuxdeployqt GitHub](https://github.com/probonopd/linuxdeployqt)
- [AppImage官方文档](https://docs.appimage.org/)
- [Qt部署指南](https://doc.qt.io/qt-5/linux-deployment.html)
