import React from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App.jsx";
import "./styles.css";
const ControlStudy = React.lazy(() => import('./ControlStudy.jsx'));
const showControlStudy = new URLSearchParams(location.search).get('study') === 'controls';
const ReadingNextStudy = React.lazy(() => import('./ReadingNextStudy.jsx'));
const showReadingNext = new URLSearchParams(location.search).get('study') === 'reading-next';

createRoot(document.getElementById("root")).render(
  <React.StrictMode>
    <React.Suspense fallback={<div style={{padding:32}}>正在打开交互稿…</div>}>
      {showReadingNext ? <ReadingNextStudy /> : showControlStudy ? <ControlStudy /> : <App />}
    </React.Suspense>
  </React.StrictMode>,
);
