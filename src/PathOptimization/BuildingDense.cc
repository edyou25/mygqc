#include "BuildingDense.h"

#include <QtGlobal>
#include <QtMath>

BuildingDense::BuildingDense(QObject* parent)
    : QObject(parent)
{
}

void BuildingDense::setBdid(int id)
{
    if (_bdid == id) {
        return;
    }
    _bdid = id;
    emit bdidChanged();
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

void BuildingDense::setPath(const QVariantList& path)
{
    // 可选：做一点点输入校验（至少3点）
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

void BuildingDense::setHeightMeters(double heightMeters)
{
    if (qFuzzyCompare(_heightMeters + 1.0, heightMeters + 1.0)) {
        return;
    }

    _heightMeters = qMax(0.0, heightMeters);
    emit heightMetersChanged();
}

void BuildingDense::setMinHeightMeters(double minHeightMeters)
{
    if (qFuzzyCompare(_minHeightMeters + 1.0, minHeightMeters + 1.0)) {
        return;
    }

    _minHeightMeters = qMax(0.0, minHeightMeters);
    emit minHeightMetersChanged();
}

void BuildingDense::setLevels(double levels)
{
    if (qFuzzyCompare(_levels + 1.0, levels + 1.0)) {
        return;
    }

    _levels = qMax(0.0, levels);
    emit levelsChanged();
}

QList<QGeoCoordinate> BuildingDense::pathCoordinates() const
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
