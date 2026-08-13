import { useState } from "react";

const VIEWS = { LOGIN: "login", REGISTER: "register", CONFIRM: "confirm" };

export function AuthModal({ auth, onClose }) {
  const [view, setView]         = useState(VIEWS.LOGIN);
  const [email, setEmail]       = useState("");
  const [password, setPassword] = useState("");
  const [code, setCode]         = useState("");
  const [error, setError]       = useState("");
  const [loading, setLoading]   = useState("");

  const clear = () => { setError(""); setLoading(""); };

  const handleLogin = async (e) => {
    e.preventDefault();
    clear();
    setLoading("Signing in…");
    try {
      await auth.login(email, password);
      onClose();
    } catch (err) {
      setError(err.message || "Sign in failed");
    } finally {
      setLoading("");
    }
  };

  const handleRegister = async (e) => {
    e.preventDefault();
    clear();
    setLoading("Creating account…");
    try {
      await auth.register(email, password);
      setView(VIEWS.CONFIRM);
    } catch (err) {
      setError(err.message || "Registration failed");
    } finally {
      setLoading("");
    }
  };

  const handleConfirm = async (e) => {
    e.preventDefault();
    clear();
    setLoading("Verifying…");
    try {
      await auth.confirm(email, code);
      await auth.login(email, password);
      onClose();
    } catch (err) {
      setError(err.message || "Verification failed");
    } finally {
      setLoading("");
    }
  };

  const handleResend = async () => {
    try {
      await auth.resendCode(email);
      setError("Code resent — check your email.");
    } catch (err) {
      setError(err.message);
    }
  };

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal" onClick={(e) => e.stopPropagation()}>
        <button className="modal-close" onClick={onClose}>✕</button>

        {view === VIEWS.LOGIN && (
          <>
            <h2>Sign in</h2>
            <form onSubmit={handleLogin}>
              <label>Email</label>
              <input type="email" value={email} onChange={e => setEmail(e.target.value)} required autoFocus />
              <label>Password</label>
              <input type="password" value={password} onChange={e => setPassword(e.target.value)} required />
              {error && <p className="form-error">{error}</p>}
              <button type="submit" className="btn-primary" disabled={!!loading}>
                {loading || "Sign in"}
              </button>
            </form>
            <p className="auth-switch">
              No account?{" "}
              <button className="link-btn" onClick={() => { setView(VIEWS.REGISTER); clear(); }}>
                Create one
              </button>
            </p>
          </>
        )}

        {view === VIEWS.REGISTER && (
          <>
            <h2>Create account</h2>
            <form onSubmit={handleRegister}>
              <label>Email</label>
              <input type="email" value={email} onChange={e => setEmail(e.target.value)} required autoFocus />
              <label>Password</label>
              <input
                type="password"
                value={password}
                onChange={e => setPassword(e.target.value)}
                required
                minLength={8}
                placeholder="Min. 8 characters"
              />
              {error && <p className="form-error">{error}</p>}
              <button type="submit" className="btn-primary" disabled={!!loading}>
                {loading || "Create account"}
              </button>
            </form>
            <p className="auth-switch">
              Already have an account?{" "}
              <button className="link-btn" onClick={() => { setView(VIEWS.LOGIN); clear(); }}>
                Sign in
              </button>
            </p>
          </>
        )}

        {view === VIEWS.CONFIRM && (
          <>
            <h2>Check your email</h2>
            <p className="confirm-hint">We sent a code to <strong>{email}</strong></p>
            <form onSubmit={handleConfirm}>
              <label>Verification code</label>
              <input
                type="text"
                value={code}
                onChange={e => setCode(e.target.value)}
                required
                autoFocus
                inputMode="numeric"
                placeholder="000000"
                className="code-input"
              />
              {error && <p className="form-error">{error}</p>}
              <button type="submit" className="btn-primary" disabled={!!loading}>
                {loading || "Verify and sign in"}
              </button>
            </form>
            <p className="auth-switch">
              Didn't get it?{" "}
              <button className="link-btn" onClick={handleResend}>Resend code</button>
            </p>
          </>
        )}
      </div>
    </div>
  );
}
