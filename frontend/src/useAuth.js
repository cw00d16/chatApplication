import { useState, useEffect, useCallback } from "react";
import {
  signIn,
  signOut,
  signUp,
  confirmSignUp,
  getCurrentUser,
  fetchAuthSession,
  resendSignUpCode,
} from "aws-amplify/auth";

export function useAuth() {
  const [user, setUser]       = useState(null);
  const [loading, setLoading] = useState(true);

  // Check if a session already exists on mount
  useEffect(() => {
    getCurrentUser()
      .then(setUser)
      .catch(() => setUser(null))
      .finally(() => setLoading(false));
  }, []);

  // Returns the JWT access token to attach to API requests
  const getToken = useCallback(async () => {
    const session = await fetchAuthSession();
    return session.tokens?.accessToken?.toString();
  }, []);

  const login = useCallback(async (email, password) => {
    const result = await signIn({ username: email, password });
    if (result.isSignedIn) {
      const u = await getCurrentUser();
      setUser(u);
    }
    return result;
  }, []);

  const logout = useCallback(async () => {
    await signOut();
    setUser(null);
  }, []);

  const register = useCallback(async (email, password) => {
    return signUp({
      username: email,
      password,
      options: { userAttributes: { email } },
    });
  }, []);

  const confirm = useCallback(async (email, code) => {
    const result = await confirmSignUp({ username: email, confirmationCode: code });
    return result;
  }, []);

  const resendCode = useCallback(async (email) => {
    return resendSignUpCode({ username: email });
  }, []);

  return { user, loading, getToken, login, logout, register, confirm, resendCode };
}
