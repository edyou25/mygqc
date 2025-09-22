/****************************************************************************
 *
 * (c) 2009-2020 QGROUNDCONTROL PROJECT <http://www.qgroundcontrol.org>
 *
 * QGroundControl is licensed according to the terms in the file
 * COPYING.md in the root of the source code directory.
 *
 ****************************************************************************/



// Allows QGlobalStatic to work on this translation unit
#define _LOG_CTOR_ACCESS_ public

#include "AppMessages.h"
#include "QGCApplication.h"
#include "SettingsManager.h"
#include "AppSettings.h"

#include <QStringListModel>
#include <QtConcurrent>
#include <QTextStream>
#include <QDir>
#include <QCoreApplication>
#include <QDateTime>

Q_GLOBAL_STATIC(AppLogModel, debug_model)

static QtMessageHandler old_handler;

static void msgHandler(QtMsgType type, const QMessageLogContext &context, const QString &msg)
{
    const char symbols[] = { 'D', 'E', '!', 'X', 'I' };
    QString output = QString("[%1] at %2:%3 - \"%4\"").arg(symbols[type]).arg(context.file).arg(context.line).arg(msg);

    // Avoid recursion
    if (!QString(context.category).startsWith("qt.quick")) {
        debug_model->log(output);
    }

    if (old_handler != nullptr) {
        old_handler(type, context, msg);
    }
    if( type == QtFatalMsg ) abort();
}

void AppMessages::installHandler()
{
    old_handler = qInstallMessageHandler(msgHandler);

    // Force creation of debug model on installing thread
    Q_UNUSED(*debug_model);
}

AppLogModel *AppMessages::getModel()
{
    return debug_model;
}

AppLogModel::AppLogModel() : QStringListModel()
{
#ifdef __mobile__
    Qt::ConnectionType contype = Qt::QueuedConnection;
#else
    Qt::ConnectionType contype = Qt::AutoConnection;
#endif
    connect(this, &AppLogModel::emitLog, this, &AppLogModel::threadsafeLog, contype);
}

void AppLogModel::writeMessages(const QString dest_file)
{
    const QString writebuffer(stringList().join('\n').append('\n'));

    QtConcurrent::run([dest_file, writebuffer] {
        emit debug_model->writeStarted();
        bool success = false;
        QFile file(dest_file);
        if (file.open(QIODevice::WriteOnly | QIODevice::Text)) {
            QTextStream out(&file);
            out << writebuffer;
            success = out.status() == QTextStream::Ok;
        } else {
            qWarning() << "AppLogModel::writeMessages write failed:" << file.errorString();
        }
        emit debug_model->writeFinished(success);
    });
}

void AppLogModel::log(const QString message)
{
    emit debug_model->emitLog(message);
}

void AppLogModel::threadsafeLog(const QString message)
{
    const int line = rowCount();
    insertRows(line, 1);
    setData(index(line), message, Qt::DisplayRole);

    if (qgcApp() && qgcApp()->logOutput() && _logFile.fileName().isEmpty()) {
        qDebug() << _logFile.fileName().isEmpty() << qgcApp()->logOutput();
        QGCToolbox* toolbox = qgcApp()->toolbox();
        // Be careful of toolbox not being open yet
        if (toolbox) {
            QString saveDirPath = qgcApp()->toolbox()->settingsManager()->appSettings()->crashSavePath();
            QDir saveDir(saveDirPath);
            QString saveFilePath = saveDir.absoluteFilePath(QStringLiteral("QGCConsole.log"));

            _logFile.setFileName(saveFilePath);
            if (!_logFile.open(QIODevice::WriteOnly | QIODevice::Text)) {
                qgcApp()->showAppMessage(tr("Open console log output file failed %1 : %2").arg(_logFile.fileName()).arg(_logFile.errorString()));
            }
        }
    }

    if (_logFile.isOpen()) {
        QTextStream out(&_logFile);
        out << message << "\n";
        _logFile.flush();
    }

    // Additional project-root log file for TowerOptimize JS module
    // Write messages containing the tag to a dedicated file under <projectRoot>/log/TowerOptimize.log
    static QFile s_towerOptimizeFile;
    static bool s_towerLogInitialized = false;
    if (message.contains("[TowerOptimize]")) {
        if (!s_towerLogInitialized) {
            s_towerLogInitialized = true;
            // Locate project root by looking for qgroundcontrol.pro file
            QDir appDir(QCoreApplication::applicationDirPath());
            QDir candidate = appDir;
            
            // First check current app directory
            if (!candidate.exists("qgroundcontrol.pro")) {
                // Check parent directory (common when running from build folder)
                QDir parent = appDir;
                parent.cdUp();
                if (parent.exists("qgroundcontrol.pro")) {
                    candidate = parent;
                } else {
                    // Check grandparent directory (in case we're in build/debug or similar)
                    QDir grandparent = parent;
                    grandparent.cdUp();
                    if (grandparent.exists("qgroundcontrol.pro")) {
                        candidate = grandparent;
                    }
                }
            }
            
            // Create log directory if it doesn't exist
            QDir logDir(candidate.filePath("log"));
            if (!logDir.exists()) {
                logDir.mkpath(".");
            }
            
            // Set up TowerOptimize log file with timestamp
            QString timestamp = QDateTime::currentDateTime().toString("yyyyMMdd_hhmmss");
            const QString towerLogPath = logDir.filePath(QString("TowerOptimize_%1.log").arg(timestamp));
            s_towerOptimizeFile.setFileName(towerLogPath);
            if (s_towerOptimizeFile.open(QIODevice::WriteOnly | QIODevice::Text)) {
                // Write header with timestamp when starting new log session
                QTextStream headerStream(&s_towerOptimizeFile);
                headerStream << "=== TowerOptimize Log Session Started at " 
                           << QDateTime::currentDateTime().toString(Qt::ISODate) << " ===\n";
                s_towerOptimizeFile.flush();
            }
        }
        
        // Write TowerOptimize message to dedicated log file
        if (s_towerOptimizeFile.isOpen()) {
            QTextStream towerStream(&s_towerOptimizeFile);
            towerStream << QDateTime::currentDateTime().toString("hh:mm:ss.zzz") 
                       << " " << message << "\n";
            s_towerOptimizeFile.flush();
        }
    }
}
