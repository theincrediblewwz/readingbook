import React from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App.jsx";
import "./styles.css";
const ControlStudy = React.lazy(() => import('./ControlStudy.jsx'));
const showControlStudy = new URLSearchParams(location.search).get('study') === 'controls';

createRoot(document.getElementById("root")).render(
  <React.StrictMode>
    <React.Suspense fallback={<div style={{padding:32}}>正在打开交互稿…</div>}>
      {showControlStudy ? <ControlStudy /> : <App />}
    </React.Suspense>
  </React.StrictMode>,
);
