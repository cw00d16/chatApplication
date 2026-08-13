import React from "react";
import ReactDOM from "react-dom/client";
import { Amplify } from "aws-amplify";
import App from "./App";
import "./index.css";

Amplify.configure({
  Auth: {
    Cognito: {
      userPoolId:       process.env.REACT_APP_COGNITO_USER_POOL,
      userPoolClientId: process.env.REACT_APP_COGNITO_CLIENT_ID,
      region:           process.env.REACT_APP_COGNITO_REGION || "us-east-2",
    },
  },
});

const root = ReactDOM.createRoot(document.getElementById("root"));
root.render(
  <React.StrictMode>
    <App />
  </React.StrictMode>
);
