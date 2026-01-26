#include "WaterArea.h"

#include <QtGlobal>

WaterArea::WaterArea(QObject* parent)
    : QObject(parent)
{
}

void WaterArea::setWid(int id)
{
    if (_wid == id) {
        return;
    }
    _wid = id;
    emit widChanged();
}

static bool _variantToCoordinate(const QVariant& v, QGeoCoordinate& out)
{
    // QML 的 coordinate 通常能直接转换成 QGeoCoordinate
    if (v.canConvert<QGeoCoordinate>()) {
        out = v.value<QGeoCoordinate>();
        return out.isValid();
    }
    return false;
}

void WaterArea::setPath(const QVariantList& path)
{
    // 可选：做一点点输入校验（至少3点）
    // 不强制也行，但能减少“坏数据”
    if (path == _path) {
        return;
    }

    // 过滤无效点（可选）
    QVariantList cleaned;
    cleaned.reserve(path.size());

    for (const QVariant& v : path) {
        QGeoCoordinate c;
        if (_variantToCoordinate(v, c)) {
            cleaned.push_back(QVariant::fromValue(c));
        }
    }

    _path = cleaned;
    emit pathChanged();
}

QList<QGeoCoordinate> WaterArea::pathCoordinates() const
{
    QList<QGeoCoordinate> out;
    out.reserve(_path.size());
    for (const QVariant& v : _path) {
        if (v.canConvert<QGeoCoordinate>()) {
            out.push_back(v.value<QGeoCoordinate>());
        }
    }
    return out;
}