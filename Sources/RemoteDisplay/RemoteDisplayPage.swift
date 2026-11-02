import Foundation

public enum RemoteDisplayPage {
    public static let fallbackHTML = """
    <!doctype html><html lang="ru"><head><meta charset="utf-8"><title>MeetingAssistant</title></head>
    <body><p>Страница удалённого экрана не найдена в сборке приложения. WebSocket-порт: __WS_PORT__.</p></body></html>
    """
}
