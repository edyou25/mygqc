#pragma once

#include <QObject>
#include <QVariantList>
#include <QGeoCoordinate>

class WaterArea : public QObject
{
    Q_OBJECT
    Q_PROPERTY(int wid READ wid WRITE setWid NOTIFY widChanged)
    Q_PROPERTY(QVariantList path READ path WRITE setPath NOTIFY pathChanged)

public:
    explicit WaterArea(QObject* parent = nullptr);

    int wid() const { return _wid; }
    void setWid(int id);

    QVariantList path() const { return _path; }
    void setPath(const QVariantList& path);

    // 便捷：直接用 QGeoCoordinate 列表（C++ 内部算法用）
    QList<QGeoCoordinate> pathCoordinates() const;

signals:
    void widChanged();
    void pathChanged();

private:
    int _wid = 0;
    QVariantList _path;   // each item is a QGeoCoordinate (QVariant)
};