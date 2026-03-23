#pragma once

#include <QObject>
#include <QVariantList>
#include <QGeoCoordinate>

class BuildingDense : public QObject
{
    Q_OBJECT
    Q_PROPERTY(int bdid READ bdid WRITE setBdid NOTIFY bdidChanged)
    Q_PROPERTY(QVariantList path READ path WRITE setPath NOTIFY pathChanged)
    Q_PROPERTY(double heightMeters READ heightMeters WRITE setHeightMeters NOTIFY heightMetersChanged)
    Q_PROPERTY(double minHeightMeters READ minHeightMeters WRITE setMinHeightMeters NOTIFY minHeightMetersChanged)
    Q_PROPERTY(double levels READ levels WRITE setLevels NOTIFY levelsChanged)

public:
    explicit BuildingDense(QObject* parent = nullptr);

    int bdid() const { return _bdid; }
    void setBdid(int id);

    QVariantList path() const { return _path; }
    void setPath(const QVariantList& path);
    double heightMeters() const { return _heightMeters; }
    void setHeightMeters(double heightMeters);
    double minHeightMeters() const { return _minHeightMeters; }
    void setMinHeightMeters(double minHeightMeters);
    double levels() const { return _levels; }
    void setLevels(double levels);

    // 便捷：直接用 QGeoCoordinate 列表（C++ 内部算法用）
    QList<QGeoCoordinate> pathCoordinates() const;

signals:
    void bdidChanged();
    void pathChanged();
    void heightMetersChanged();
    void minHeightMetersChanged();
    void levelsChanged();

private:
    int _bdid = 0;
    QVariantList _path;   // each item is a QGeoCoordinate (QVariant)
    double _heightMeters = 0.0;
    double _minHeightMeters = 0.0;
    double _levels = 0.0;
};
