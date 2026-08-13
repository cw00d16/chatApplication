import { useState, useEffect, useRef, useCallback } from "react";

const WS_URL = process.env.REACT_APP_WEBSOCKET_URL;
const MAX_RECONNECT_DELAY_MS = 30000;

// ---------------------------------------------------------------
// One WebSocket connection lives for the whole authenticated session —
// switching rooms sends a "joinRoom" message over it rather than
// reconnecting, since $connect re-verifies the JWT and is the
// expensive step.
//
// If the socket drops unexpectedly (WiFi blip, API Gateway's 10-minute
// idle timeout / 2-hour hard max connection lifetime, a backend deploy),
// this reconnects automatically with exponential backoff (1s, 2s, 4s...
// capped at 30s), and re-runs joinRoom for whatever room we were in —
// which re-fetches that room's recent history, so reconnecting also
// catches the client up on anything sent while it was disconnected.
// That catch-up is only as deep as the last 50 messages joinRoom
// already fetches, not a precise "everything since the exact message
// you last saw" resync — fine for a UI-level gap, worth knowing about
// as a simplification.
// ---------------------------------------------------------------
export function useChatSocket(auth, displayName) {
  const [status, setStatus]           = useState("idle"); // idle | connecting | open | reconnecting | error
  const [messages, setMessages]       = useState([]);
  const [currentRoomId, setCurrentRoomId] = useState(null);

  const wsRef = useRef(null);
  const pendingRoomRef = useRef(null);
  const currentRoomRef = useRef(null);
  const reconnectAttemptRef = useRef(0);
  const reconnectTimerRef = useRef(null);
  const intentionalCloseRef = useRef(false);

  useEffect(() => {
    if (!auth.user || !displayName) return;

    intentionalCloseRef.current = false;

    const connect = async () => {
      const token = await auth.getToken();
      if (intentionalCloseRef.current || !token) return;

      setStatus(reconnectAttemptRef.current > 0 ? "reconnecting" : "connecting");

      const ws = new WebSocket(
        `${WS_URL}?token=${encodeURIComponent(token)}&displayName=${encodeURIComponent(displayName)}`
      );
      wsRef.current = ws;

      ws.onopen = () => {
        setStatus("open");
        reconnectAttemptRef.current = 0;

        const roomToRejoin = currentRoomRef.current || pendingRoomRef.current;
        if (roomToRejoin) {
          ws.send(JSON.stringify({ action: "joinRoom", roomId: roomToRejoin }));
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

      ws.onclose = () => {
        if (intentionalCloseRef.current) return;

        setStatus("reconnecting");
        const attempt = reconnectAttemptRef.current;
        const delay = Math.min(1000 * 2 ** attempt, MAX_RECONNECT_DELAY_MS);
        reconnectAttemptRef.current = attempt + 1;
        reconnectTimerRef.current = setTimeout(connect, delay);
      };

      // onclose always fires right after onerror on a failed/dropped
      // connection, so the retry itself is scheduled there — this just
      // surfaces the failure in status for the moment before it does.
      ws.onerror = () => setStatus("error");
    };

    connect();

    return () => {
      intentionalCloseRef.current = true;
      clearTimeout(reconnectTimerRef.current);
      reconnectAttemptRef.current = 0;
      wsRef.current?.close();
      wsRef.current = null;
    };
  }, [auth.user, displayName]);

  const joinRoom = useCallback((roomId) => {
    setMessages([]);
    setCurrentRoomId(roomId);
    currentRoomRef.current = roomId;
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
