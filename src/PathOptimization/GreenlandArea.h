#pragma once
#include <QObject>
#include <QVariantList>
#include <QtPositioning/QGeoCoordinate>

class GreenlandArea : public QObject {
    Q_OBJECT
    Q_PROPERTY(int gid READ gid WRITE setGid NOTIFY gidChanged)
    Q_PROPERTY(QVariantList path READ path WRITE setPath NOTIFY pathChanged) // list of QGeoCoordinate (as QVariant)

public:
    explicit GreenlandArea(QObject* parent = nullptr);
    int gid() const { return _gid; }
    void setGid(int gid) {
        if (_gid == gid) return;
        _gid = gid;
        emit gidChanged();
    }

    QVariantList path() const { return _path; }
    void setPath(const QVariantList& p) {
        _path = p;
        emit pathChanged();
    }

signals:
    void gidChanged();
    void pathChanged();

private:
    int _gid = -1;
    QVariantList _path;
};