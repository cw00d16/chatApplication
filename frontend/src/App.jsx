import { useState, useEffect, useCallback, useRef } from "react";
import { useAuth } from "./useAuth";
import { AuthModal } from "./AuthModal";
import { useChatSocket } from "./useChatSocket";
import { api } from "./api";

function DisplayNamePrompt({ onSet }) {
  const [name, setName] = useState("");
  return (
    <div className="name-prompt">
      <h2>Pick a display name</h2>
      <p className="name-prompt-hint">Shown next to your messages in every room.</p>
      <form onSubmit={(e) => { e.preventDefault(); if (name.trim()) onSet(name.trim()); }}>
        <input
          className="main-input"
          value={name}
          onChange={(e) => setName(e.target.value)}
          placeholder="e.g. Alex"
          autoFocus
          maxLength={30}
        />
        <button className="shorten-btn" type="submit" disabled={!name.trim()}>
          Continue →
        </button>
      </form>
    </div>
  );
}

function RoomList({ rooms, currentRoomId, onSelect, onCreate, loading }) {
  const [newRoomName, setNewRoomName] = useState("");
  const [creating, setCreating] = useState(false);

  const handleCreate = async (e) => {
    e.preventDefault();
    if (!newRoomName.trim()) return;
    setCreating(true);
    try {
      await onCreate(newRoomName.trim());
      setNewRoomName("");
    } finally {
      setCreating(false);
    }
  };

  return (
    <div className="room-list">
      <form className="room-create" onSubmit={handleCreate}>
        <input
          value={newRoomName}
          onChange={(e) => setNewRoomName(e.target.value)}
          placeholder="New room name"
          maxLength={40}
        />
        <button type="submit" disabled={creating || !newRoomName.trim()}>+</button>
      </form>

      {loading && <div className="loading-row">Loading…</div>}
      {!loading && rooms.length === 0 && <div className="empty">No rooms yet — create one.</div>}

      <div className="room-items">
        {rooms.map((r) => (
          <button
            key={r.roomId}
            className={`room-item ${r.roomId === currentRoomId ? "active" : ""}`}
            onClick={() => onSelect(r.roomId)}
          >
            # {r.name}
          </button>
        ))}
      </div>
    </div>
  );
}

function MessageList({ messages, userId }) {
  const bottomRef = useRef(null);

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [messages]);

  return (
    <div className="message-list">
      {messages.map((m) => (
        <div key={m.messageId} className={`message ${m.userId === userId ? "own" : ""}`}>
          <div className="message-meta">
            <span className="message-author">{m.displayName}</span>
            <span className="message-time">
              {new Date(m.createdAt).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}
            </span>
          </div>
          <div className="message-body">{m.body}</div>
        </div>
      ))}
      <div ref={bottomRef} />
    </div>
  );
}

function ChatDashboard({ auth, displayName }) {
  const [rooms, setRooms] = useState([]);
  const [loadingRooms, setLoadingRooms] = useState(true);
  const [draft, setDraft] = useState("");

  const chat = useChatSocket(auth, displayName);

  const loadRooms = useCallback(async () => {
    try {
      const data = await api.listRooms(auth.getToken);
      setRooms(data);
    } catch (e) {
      console.error("Failed to load rooms", e);
    } finally {
      setLoadingRooms(false);
    }
  }, [auth.getToken]);

  useEffect(() => { loadRooms(); }, [loadRooms]);

  const handleCreateRoom = async (name) => {
    const room = await api.createRoom(name, auth.getToken);
    setRooms((prev) => [{ roomId: room.roomId, name: room.name, createdAt: room.createdAt }, ...prev]);
    chat.joinRoom(room.roomId);
  };

  const handleSend = () => {
    if (!draft.trim()) return;
    chat.sendMessage(draft.trim());
    setDraft("");
  };

  const currentRoom = rooms.find((r) => r.roomId === chat.currentRoomId);
  const userId = auth.user?.userId || auth.user?.username;

  return (
    <div className="chat-dashboard">
      <aside className="sidebar">
        <RoomList
          rooms={rooms}
          currentRoomId={chat.currentRoomId}
          onSelect={chat.joinRoom}
          onCreate={handleCreateRoom}
          loading={loadingRooms}
        />
      </aside>

      <section className="chat-panel">
        {!chat.currentRoomId && (
          <div className="empty chat-empty">Pick a room, or create one, to start chatting.</div>
        )}

        {chat.currentRoomId && (
          <>
            <div className="chat-header">
              <h2># {currentRoom?.name || chat.currentRoomId}</h2>
              <span className={`ws-status ws-${chat.status}`}>{chat.status}</span>
            </div>

            <MessageList messages={chat.messages} userId={userId} />

            <div className="composer">
              <input
                className="composer-input"
                value={draft}
                onChange={(e) => setDraft(e.target.value)}
                onKeyDown={(e) => e.key === "Enter" && handleSend()}
                placeholder={chat.status === "reconnecting" ? "Reconnecting…" : "Message…"}
                disabled={chat.status !== "open"}
              />
              <button className="shorten-btn" onClick={handleSend} disabled={chat.status !== "open"}>
                Send →
              </button>
            </div>
          </>
        )}
      </section>
    </div>
  );
}

export default function App() {
  const auth = useAuth();
  const [showAuth, setShowAuth] = useState(false);
  const [displayName, setDisplayName] = useState(() => localStorage.getItem("chat_display_name") || "");

  const setAndPersistName = (name) => {
    localStorage.setItem("chat_display_name", name);
    setDisplayName(name);
  };

  if (auth.loading) {
    return (
      <div className="app">
        <div className="splash">Loading…</div>
      </div>
    );
  }

  return (
    <div className="app">
      <header className="header">
        <div className="header-inner">
          <div className="logo">
            <span className="logo-icon">◆</span>chat
          </div>
          <nav className="header-nav">
            {auth.user ? (
              <>
                <span className="user-email">
                  {auth.user.signInDetails?.loginId || auth.user.username}
                </span>
                <button className="nav-btn" onClick={auth.logout}>Sign out</button>
              </>
            ) : (
              <button className="nav-btn primary" onClick={() => setShowAuth(true)}>
                Sign in
              </button>
            )}
          </nav>
        </div>
      </header>

      <main className="main">
        {auth.user && displayName && <ChatDashboard auth={auth} displayName={displayName} />}

        {auth.user && !displayName && (
          <DisplayNamePrompt onSet={setAndPersistName} />
        )}

        {!auth.user && (
          <div className="hero">
            <div className="hero-eyebrow">Chat App</div>
            <h1>Real-time rooms.<br />Serverless end to end.</h1>
            <p>Multi-room chat backed by API Gateway WebSockets,<br />Lambda, and DynamoDB.</p>
            <button className="hero-btn" onClick={() => setShowAuth(true)}>
              Get started free →
            </button>
            <div className="hero-stack">
              {["S3", "CloudFront", "API Gateway WS", "Lambda", "DynamoDB", "Cognito"].map(s => (
                <span key={s} className="stack-pill">{s}</span>
              ))}
            </div>
          </div>
        )}
      </main>

      {showAuth && <AuthModal auth={auth} onClose={() => setShowAuth(false)} />}
    </div>
  );
}
