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
#include <QRegExp>
#include <QRegExp>

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
            
            // Get project root path (reuse the same logic as file initialization)
            static QString s_projectRootPath;
            if (s_projectRootPath.isEmpty()) {
                QDir appDir(QCoreApplication::applicationDirPath());
                QDir projectCandidate = appDir;
                
                // Find project root by looking for qgroundcontrol.pro
                if (!projectCandidate.exists("qgroundcontrol.pro")) {
                    QDir parent = appDir;
                    parent.cdUp();
                    if (parent.exists("qgroundcontrol.pro")) {
                        projectCandidate = parent;
                    } else {
                        QDir grandparent = parent;
                        grandparent.cdUp();
                        if (grandparent.exists("qgroundcontrol.pro")) {
                            projectCandidate = grandparent;
                        }
                    }
                }
                s_projectRootPath = projectCandidate.absolutePath();
            }
            
            // Parse and reformat the message
            QString cleanMessage = message;
            QString filePath;
            QString lineNumber;
            QString logLevel;
            
            // Extract log level, file path and line number from Qt debug format
            // Format: "[D] at qrc:/qml/TowerOptimize.js:123 - \"[TowerOptimize] message\""
            QRegExp debugRegex("\\[(.)\\] at ([^:]+):(\\d+) - \"(.*)\"");
            if (debugRegex.indexIn(message) != -1) {
                logLevel = debugRegex.cap(1);
                QString originalPath = debugRegex.cap(2);
                lineNumber = debugRegex.cap(3);
                cleanMessage = debugRegex.cap(4);

                
                // Convert qrc path to absolute file system path
                if (originalPath.startsWith("qrc:/qml/")) {
                    QString relativePath = QString("src/PlanView/%1").arg(originalPath.mid(9));
                    filePath = QDir(s_projectRootPath).filePath(relativePath);
                } else if (originalPath.startsWith("qrc:/")) {
                    // Handle other qrc paths
                    QString relativePath = originalPath.mid(5); // Remove qrc:/ prefix
                    if (relativePath.startsWith("controls/")) {
                        relativePath = QString("src/QmlControls/%1").arg(relativePath.mid(9));
                    } else if (relativePath.startsWith("Vehicle/")) {
                        relativePath = QString("src/Vehicle/%1").arg(relativePath.mid(8));
                    } else {
                        relativePath = QString("src/%1").arg(relativePath);
                    }
                    filePath = QDir(s_projectRootPath).filePath(relativePath);
                } else {
                    // Already a real path, check if absolute or make it absolute
                    if (QDir::isAbsolutePath(originalPath)) {
                        filePath = originalPath;
                    } else {
                        filePath = QDir(s_projectRootPath).filePath(originalPath);
                    }
                }
            } else {
                // Fallback: parse message manually if regex fails
                cleanMessage = message;
                // Try to extract log level and path information from raw message
                int levelStart = message.indexOf('[');
                int levelEnd = message.indexOf(']');
                if (levelStart != -1 && levelEnd != -1 && levelEnd > levelStart) {
                    logLevel = message.mid(levelStart + 1, levelEnd - levelStart - 1);
                }
                
                int atIndex = message.indexOf("] at ");
                int dashIndex = message.indexOf(" - ");
                if (atIndex != -1 && dashIndex != -1) {
                    QString pathPart = message.mid(atIndex + 5, dashIndex - atIndex - 5);
                    int colonIndex = pathPart.lastIndexOf(':');
                    if (colonIndex != -1) {
                        QString originalPath = pathPart.left(colonIndex);
                        lineNumber = pathPart.mid(colonIndex + 1);
                        
                        // Convert qrc path to absolute path
                        if (originalPath.startsWith("qrc:/qml/")) {
                            QString relativePath = QString("src/PlanView/%1").arg(originalPath.mid(9));
                            filePath = QDir(s_projectRootPath).filePath(relativePath);
                        } else if (originalPath.startsWith("qrc:/")) {
                            QString relativePath = QString("src/%1").arg(originalPath.mid(5));
                            filePath = QDir(s_projectRootPath).filePath(relativePath);
                        } else {
                            if (QDir::isAbsolutePath(originalPath)) {
                                filePath = originalPath;
                            } else {
                                filePath = QDir(s_projectRootPath).filePath(originalPath);
                            }
                        }
                        
                        // Extract clean message after dash
                        int quoteStart = message.indexOf("\"", dashIndex);
                        int quoteEnd = message.lastIndexOf("\"");
                        if (quoteStart != -1 && quoteEnd != -1 && quoteEnd > quoteStart) {
                            cleanMessage = message.mid(quoteStart + 1, quoteEnd - quoteStart - 1);
                        }
                    }
                }
            }
            
            // Remove [TowerOptimize] tag from the message content
            cleanMessage = cleanMessage.replace("[TowerOptimize] ", "");
            cleanMessage = cleanMessage.replace("[TowerOptimize][RRT] ", "");
            cleanMessage = cleanMessage.replace("[TowerOptimize]", "");
            
            // Format: timestamp [level] message - filepath:line
            towerStream << QDateTime::currentDateTime().toString("hh:mm:ss.zzz") << " ";
            if (!logLevel.isEmpty()) {
                towerStream << "[" << logLevel << "] ";
            }
            towerStream << cleanMessage.trimmed();
            if (!filePath.isEmpty() && !lineNumber.isEmpty()) {
                towerStream << " [" << filePath << ":" << lineNumber << "]";
            }
            towerStream << "\n";
            s_towerOptimizeFile.flush();
        }
    }
}


