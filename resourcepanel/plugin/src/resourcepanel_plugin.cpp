#include "telemetry.h"

#include <QQmlEngine>
#include <QQmlExtensionPlugin>

/**
 * Registers the Telemetry singleton for the org.murasaki.resourcepanel module.
 *
 * A singleton instance (rather than a QML-declared type) is used deliberately:
 * the polling timer must exist exactly once no matter how many applet instances
 * are on screen, and it must keep running while any of them is alive.
 */
class ResourcePanelPlugin : public QQmlExtensionPlugin
{
    Q_OBJECT
    Q_PLUGIN_METADATA(IID QQmlExtensionInterface_iid
                      URI "org.murasaki.resourcepanel")

public:
    void registerTypes(const char *uri) override
    {
        qmlRegisterSingletonType<Telemetry>(uri, 1, 0, "Telemetry",
            [](QQmlEngine *engine, QJSEngine *) -> QObject * {
                auto *telemetry = new Telemetry(engine);
                return telemetry;
            });
    }
};

#include "resourcepanel_plugin.moc"
