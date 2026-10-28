# Prototype module contract

This is a local React/Vite interaction prototype with example data only. No real API calls or key persistence. Selected style and screen targets are in `../../2026-10-ui-study/styles/frost-silver.png` and `../../2026-10-ui-study/screens/`.

## Shared imports

From `../shared.jsx`:

- `useApp()` -> `{ state, update, navigate, notify, confirm, book }`.
- `update(patch)` shallow-merges state. `update(prev => ({...prev, field: value}))` also supported. Always use functional updates when based on previous state.
- `navigate(route, payload = {})` updates route and optional `selectedDocId`, `source`, `currentBookId`. Route names: `library, reader, workflow, chat, notes, map, mindmap, relations, knowledge, atlas, cards, plugins, models, trash`.
- `notify(text)` ephemeral visible status. `confirm({title,body,confirmLabel='确认',danger=false})` async boolean, custom modal, no native browser dialogs.
- `Icon({name,size=20,weight='regular',...})` Phosphor library. Names: book,library,reader,workflow,chat,notes,map,mindmap,relations,knowledge,atlas,cards,plugins,models,trash,search,plus,minus,close,chevronLeft,chevronRight,chevronDown,more,expand,collapse,grip,check,warning,info,save,download,upload,link,eye,eyeOff,play,pause,refresh,return,settings,arrowRight,copy,quote,highlight,lock,sparkle,file,filter,target,keyboard,undo,clock,stop,edit. Unknown name falls back to file.
- `Button({icon,children,variant='default',...buttonProps})`; variants default/primary/quiet/danger, always44px hit height. Supply aria-label for icon-only.
- `Panel({id,title,children,width=320,dock='right',initial,actions,footer,className='',snap=false})`: movable absolute glass window, draggable header, internal collapse/close+restore tray; width clamps at narrow sizes. dock supports left/right/bottom-left/bottom-center/bottom-right/center. initial optional `{x,y}` in viewport coordinates. snap true snaps to four corners or bottom-center on drag end. Don't position/fix Panel again in page CSS. Content can scroll. Panel internally preserves its position during drag and clamps on resize; close creates a restore button in global tray.
- `Toolbar({children,className=''})` bottom center glass controls, override via additional class if necessary.
- `Modal({title,children,onClose,footer})` focus-managed modal with visible close, Escape and focus restoration.
- `Markdown({text,className=''})` safe Markdown with real KaTeX `$`/`$$` rendering.
- `Empty({icon,title,children,action})` plain empty state.

## State schema (root owns initial values)

- `currentBookId`: math or history. `book={id,title,author,kind,pages}`.
- `documents`: `{id,bookId,title,markdown,deleted:false,source:{page,chapter,text},updatedAt}`. Six history docs ids `h-main,h-alliance,h-fire,h-people,h-question,h-understanding`; four math docs `math-note,m-pivot,m-matrix,m-question`. `selectedDocId` default math-note.
- `graphNodes`: `{id,bookId,docId,x,y}`; node ids `n-` plus doc id. `graphEdges`: `{id,bookId,from,to,label}`; from/to refer node ids. Document deletion sets deleted, do not remove node so restore recovers identity. Graph hides deleted docs.
- `profiles`: `{id,name,provider,baseURL,modelId,maxTokens,maxOutputTokens,vision,status,example:true}`. Four demo profiles deepseek,qwen,openai,claude. `activeProfileId`.
- `enabledPlugins`: array of ids `reader,spatial,mindmap,knowledge,workflow` initially. `addedComponents`: `spatial,mindmap,knowledge,cards,relations` initially. Fixed reader/workflow/chat/notes shouldn't reappear as addable components.
- `typeDefinitions`: `{id,bookId,name,fields:[string],origin}`; theorem math default, person/event/place history. Can extend.
- `readingMethods`: `{id,name,description,steps:[string]}` (close/sq3r/proof). `workflow`: `{status:'idle',receipts:[],pluginLog:[],methodId:'close',cursor:0}`. Extend fields if useful, retain existing keys.
- `readingScope`: book/current; `timeRange`:[208,209]. Shared map/relations scope must remain visible.
- `messages`: `{id,role:'user'|'assistant',text,bookId}`; no API.
- `annotations`: `{id,bookId,page,text,note,color,deleted}`.
- `source`: `{page,paragraph,text}` used by precise return to reader. `page`:1 by default.

## Assignment boundaries

- Spatial agent: only `pages/Spatial.jsx` and `pages/spatial.css`; exports MapPage, MindmapPage, RelationsPage. Sample terrain `/assets/map-terrain.png` is illustrative, not survey data. Render actual dynamic data connections, not a background screenshot. Selected map demo uses history; if math selected offer an explicit button to switch to history, don't invent people/places for math.
- Notes agent: only `pages/Notes.jsx` and `pages/notes.css`; exports NotesPage, ChatPage, KnowledgePage, SearchPanel, TrashPage. SearchPanel optional own modal. All pages no props, useApp. Dirty navigation guard can use registerDirty if needed: root supports `registerGuard(fn)` returning unsubscribe; fn async boolean. Notes should guard whenever a draft is dirty; dialog can be local Modal.
- Settings agent: only `pages/Settings.jsx` and `pages/settings.css`; exports PluginsPage, ModelsPage, WorkflowPage. Pages no props. Use sample parameters only, don't call real providers. No actual key entry allowed: input disabled/readOnly masked sample. Root header primary dispatches `window.dispatchEvent(new CustomEvent('prototype-primary'))`; listen with cleanup if you want Save/Import/New at top; also include contextual actions when helpful. Models form can keep local state and root guard.

Root owns App.jsx/shared.jsx/data.js/styles.css, Reader/library/objects pages, npm installs and browser QA. No module edits global CSS selectors; prefix page CSS. Make interactive actions semantic native buttons/inputs with accessible names and no unlabeled glyphs. Single clicks on list rows hit the entire row. Ensure overflow scroll and narrow window behavior. Do not commit.
