import { useState, useEffect, useRef, useCallback } from "react";

const WS_URL = process.env.REACT_APP_WEBSOCKET_URL;

// ---------------------------------------------------------------
// One WebSocket connection lives for the whole authenticated session —
// switching rooms sends a "joinRoom" message over it rather than
// reconnecting, since $connect re-verifies the JWT and is the
// expensive step.
// ---------------------------------------------------------------
export function useChatSocket(auth, displayName) {
  const [status, setStatus]           = useState("idle"); // idle | connecting | open | closed | error
  const [messages, setMessages]       = useState([]);
  const [currentRoomId, setCurrentRoomId] = useState(null);

  const wsRef = useRef(null);
  const pendingRoomRef = useRef(null);

  useEffect(() => {
    if (!auth.user || !displayName) return;

    let cancelled = false;
    let ws;

    (async () => {
      const token = await auth.getToken();
      if (cancelled || !token) return;

      setStatus("connecting");
      ws = new WebSocket(
        `${WS_URL}?token=${encodeURIComponent(token)}&displayName=${encodeURIComponent(displayName)}`
      );
      wsRef.current = ws;

      ws.onopen = () => {
        setStatus("open");
        if (pendingRoomRef.current) {
          ws.send(JSON.stringify({ action: "joinRoom", roomId: pendingRoomRef.current }));
        }
      };

      ws.onmessage = (event) => {
        const data = JSON.parse(event.data);
        if (data.type === "history") {
          setMessages(data.messages);
        } else if (data.type === "message") {
          setMessages((prev) => [...prev, data.message]);
        }
      };

      ws.onclose = () => setStatus("closed");
      ws.onerror = () => setStatus("error");
    })();

    return () => {
      cancelled = true;
      ws?.close();
      wsRef.current = null;
    };
  }, [auth, auth.user, displayName]);

  const joinRoom = useCallback((roomId) => {
    setMessages([]);
    setCurrentRoomId(roomId);
    pendingRoomRef.current = roomId;

    const ws = wsRef.current;
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ action: "joinRoom", roomId }));
    }
  }, []);

  const sendMessage = useCallback((body) => {
    const ws = wsRef.current;
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ action: "sendMessage", body }));
    }
  }, []);

  return { status, messages, currentRoomId, joinRoom, sendMessage };
}
