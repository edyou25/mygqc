#!/bin/bash
# QGroundControl AppImage 自动化部署脚本
# 用途: 编译并打包QGroundControl为自包含的AppImage
# 作者: Auto-generated
# 日期: 2025-11-17

set -e  # 遇到错误立即退出

# ============= 配置参数 =============
PROJECT_ROOT="/home/hw/qgroundcontrol"
BUILD_DIR="$PROJECT_ROOT/build"
DEPLOY_DIR="$PROJECT_ROOT/deploy"
TMP_DIR="/home/hw/tmp"
APPDIR="$TMP_DIR/AppDir-QGC"
QT_DIR="/home/hw/Qt/5.15.2/gcc_64"
LINUXDEPLOYQT="$TMP_DIR/linuxdeployqt.AppImage"

# 输出文件名
OUTPUT_NAME="QGroundControl-Fixed.AppImage"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ============= 辅助函数 =============
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# ============= 检查前置条件 =============
check_prerequisites() {
    log_info "检查前置条件..."
    
    # 检查Qt安装
    if [ ! -d "$QT_DIR" ]; then
        log_error "Qt未找到: $QT_DIR"
        exit 1
    fi
    
    # 检查qmake
    if [ ! -f "$QT_DIR/bin/qmake" ]; then
        log_error "qmake未找到: $QT_DIR/bin/qmake"
        exit 1
    fi
    
    # 检查项目目录
    if [ ! -d "$PROJECT_ROOT" ]; then
        log_error "项目目录未找到: $PROJECT_ROOT"
        exit 1
    fi
    
    log_info "前置条件检查通过"
}

# ============= 编译项目 =============
build_project() {
    log_info "开始编译QGroundControl..."
    
    cd "$PROJECT_ROOT"
    
    # 如果build目录不存在，创建并配置
    if [ ! -d "$BUILD_DIR" ]; then
        log_info "创建build目录并配置CMake..."
        mkdir -p "$BUILD_DIR"
        cd "$BUILD_DIR"
        cmake .. \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_PREFIX_PATH="$QT_DIR"
    else
        cd "$BUILD_DIR"
    fi
    
    # 编译
    log_info "编译中 (使用 $(nproc) 个CPU核心)..."
    cmake --build . -j$(nproc)
    
    # 检查可执行文件
    if [ ! -f "$BUILD_DIR/QGroundControl" ]; then
        log_error "编译失败: QGroundControl可执行文件未生成"
        exit 1
    fi
    
    log_info "编译完成: $BUILD_DIR/QGroundControl"
}

# ============= 下载linuxdeployqt =============
download_linuxdeployqt() {
    if [ -f "$LINUXDEPLOYQT" ]; then
        log_info "linuxdeployqt已存在，跳过下载"
        return
    fi
    
    log_info "下载linuxdeployqt..."
    mkdir -p "$TMP_DIR"
    cd "$TMP_DIR"
    
    curl -L -o "$LINUXDEPLOYQT" \
        https://github.com/probonopd/linuxdeployqt/releases/download/continuous/linuxdeployqt-continuous-x86_64.AppImage
    
    chmod +x "$LINUXDEPLOYQT"
    log_info "linuxdeployqt下载完成"
}

# ============= 准备AppDir =============
prepare_appdir() {
    log_info "准备AppDir目录结构..."
    
    # 清理旧文件
    if [ -d "$APPDIR" ]; then
        log_warn "清理旧的AppDir: $APPDIR"
        rm -rf "$APPDIR"
    fi
    
    # 创建目录结构
    mkdir -p "$APPDIR/usr/bin"
    mkdir -p "$APPDIR/usr/share/applications"
    mkdir -p "$APPDIR/usr/share/icons/hicolor/512x512/apps"
    
    # 复制可执行文件
    log_info "复制QGroundControl可执行文件..."
    cp "$BUILD_DIR/QGroundControl" "$APPDIR/usr/bin/"
    
    # 复制desktop文件
    log_info "复制desktop文件..."
    if [ -f "$DEPLOY_DIR/org.mavlink.qgroundcontrol.desktop" ]; then
        cp "$DEPLOY_DIR/org.mavlink.qgroundcontrol.desktop" \
           "$APPDIR/usr/share/applications/qgroundcontrol.desktop"
    else
        log_error "Desktop文件未找到: $DEPLOY_DIR/org.mavlink.qgroundcontrol.desktop"
        exit 1
    fi
    
    # 复制图标
    log_info "复制应用图标..."
    ICON_FOUND=false
    
    # 尝试多个可能的图标位置
    for icon_path in \
        "$PROJECT_ROOT/resources/icons/qgroundcontrol.png" \
        "$DEPLOY_DIR/qgroundcontrol.png" \
        "$PROJECT_ROOT/qgroundcontrol.png"; do
        
        if [ -f "$icon_path" ]; then
            cp "$icon_path" "$APPDIR/usr/share/icons/hicolor/512x512/apps/qgroundcontrol.png"
            # 同时复制到顶层目录（AppImage要求）
            cp "$icon_path" "$APPDIR/org.mavlink.qgroundcontrol.png"
            ICON_FOUND=true
            log_info "图标已复制: $icon_path"
            break
        fi
    done
    
    if [ "$ICON_FOUND" = false ]; then
        log_error "图标文件未找到"
        exit 1
    fi
    
    # 创建qt.conf (可选，linuxdeployqt会覆盖)
    cat > "$APPDIR/usr/bin/qt.conf" << 'EOF'
[Paths]
Plugins=plugins
Imports=qml
Qml2Imports=qml
EOF
    
    log_info "AppDir准备完成"
}

# ============= 部署Qt依赖 =============
deploy_qt_dependencies() {
    log_info "部署Qt库和依赖..."
    
    cd "$TMP_DIR"
    
    "$LINUXDEPLOYQT" \
        "$APPDIR/usr/share/applications/qgroundcontrol.desktop" \
        -always-overwrite \
        -bundle-non-qt-libs \
        -qmldir="$PROJECT_ROOT/src" \
        -qmake="$QT_DIR/bin/qmake" \
        -verbose=1
    
    if [ $? -ne 0 ]; then
        log_error "Qt依赖部署失败"
        exit 1
    fi
    
    log_info "Qt依赖部署完成"
}

# ============= 生成AppImage =============
generate_appimage() {
    log_info "生成AppImage..."
    
    cd "$TMP_DIR"
    
    # 删除旧的AppImage
    if [ -f "$TMP_DIR/QGroundControl-x86_64.AppImage" ]; then
        rm -f "$TMP_DIR/QGroundControl-x86_64.AppImage"
    fi
    
    ARCH=x86_64 "$LINUXDEPLOYQT" \
        "$APPDIR/usr/share/applications/qgroundcontrol.desktop" \
        -appimage \
        -qmake="$QT_DIR/bin/qmake"
    
    if [ $? -ne 0 ]; then
        log_error "AppImage生成失败"
        exit 1
    fi
    
    # 检查生成的文件
    if [ ! -f "$TMP_DIR/QGroundControl-x86_64.AppImage" ]; then
        log_error "AppImage文件未生成: $TMP_DIR/QGroundControl-x86_64.AppImage"
        exit 1
    fi
    
    log_info "AppImage生成成功"
}

# ============= 复制到部署目录 =============
copy_to_deploy() {
    log_info "复制AppImage到部署目录..."
    
    mkdir -p "$DEPLOY_DIR"
    
    cp "$TMP_DIR/QGroundControl-x86_64.AppImage" \
       "$DEPLOY_DIR/$OUTPUT_NAME"
    
    chmod +x "$DEPLOY_DIR/$OUTPUT_NAME"
    
    log_info "部署完成: $DEPLOY_DIR/$OUTPUT_NAME"
}

# ============= 显示信息 =============
show_summary() {
    echo ""
    echo "============================================"
    log_info "部署总结"
    echo "============================================"
    
    if [ -f "$DEPLOY_DIR/$OUTPUT_NAME" ]; then
        FILE_SIZE=$(ls -lh "$DEPLOY_DIR/$OUTPUT_NAME" | awk '{print $5}')
        echo "文件位置: $DEPLOY_DIR/$OUTPUT_NAME"
        echo "文件大小: $FILE_SIZE"
        echo ""
        
        log_info "验证AppImage..."
        if "$DEPLOY_DIR/$OUTPUT_NAME" --appimage-help > /dev/null 2>&1; then
            echo -e "${GREEN}✓${NC} AppImage格式正确"
        else
            log_warn "AppImage格式验证失败"
        fi
        
        echo ""
        echo "使用方法:"
        echo "  1. 直接运行:"
        echo "     $DEPLOY_DIR/$OUTPUT_NAME"
        echo ""
        echo "  2. 提取并运行 (不需要FUSE):"
        echo "     $DEPLOY_DIR/$OUTPUT_NAME --appimage-extract-and-run"
        echo ""
        echo "  3. 提取内容查看:"
        echo "     $DEPLOY_DIR/$OUTPUT_NAME --appimage-extract"
        echo ""
    else
        log_error "部署文件未找到"
        exit 1
    fi
}

# ============= 清理临时文件 (可选) =============
cleanup_temp() {
    if [ "$KEEP_TEMP" != "1" ]; then
        log_info "清理临时文件..."
        rm -rf "$APPDIR"
        rm -f "$TMP_DIR/QGroundControl-x86_64.AppImage"
        log_info "清理完成"
    else
        log_info "保留临时文件 (KEEP_TEMP=1)"
        echo "AppDir位置: $APPDIR"
    fi
}

# ============= 主流程 =============
main() {
    echo ""
    echo "============================================"
    echo "  QGroundControl AppImage 自动化部署"
    echo "============================================"
    echo ""
    
    # 解析命令行参数
    SKIP_BUILD=0
    KEEP_TEMP=0
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --skip-build)
                SKIP_BUILD=1
                shift
                ;;
            --keep-temp)
                KEEP_TEMP=1
                shift
                ;;
            --help|-h)
                echo "用法: $0 [选项]"
                echo ""
                echo "选项:"
                echo "  --skip-build    跳过编译，直接打包已有的可执行文件"
                echo "  --keep-temp     保留临时文件 (AppDir)"
                echo "  --help, -h      显示此帮助信息"
                echo ""
                exit 0
                ;;
            *)
                log_error "未知选项: $1"
                echo "使用 --help 查看帮助"
                exit 1
                ;;
        esac
    done
    
    # 执行步骤
    check_prerequisites
    
    if [ "$SKIP_BUILD" -eq 0 ]; then
        build_project
    else
        log_warn "跳过编译步骤 (--skip-build)"
    fi
    
    download_linuxdeployqt
    prepare_appdir
    deploy_qt_dependencies
    generate_appimage
    copy_to_deploy
    cleanup_temp
    show_summary
    
    echo ""
    log_info "全部完成！"
    echo ""
}

# 执行主流程
main "$@"
