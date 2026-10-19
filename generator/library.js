/* The SQLite library is available through the optional local Python server. */
(() => {
  const api = new URL('../api/', location.href);
  let entries = [];
  let selectedId = null;
  const message = text => { $('library-status').textContent = text; };
  async function request(path, options = {}) {
    const response = await fetch(new URL(path, api), { ...options, cache: 'no-store' });
    if (!response.ok) {
      const data = await response.json().catch(() => ({}));
      throw new Error(data.error || 'Library request failed (' + response.status + ').');
    }
    return response.json();
  }
  function selection(entry) {
    selectedId = entry ? entry.id : null;
    $('library-list').value = selectedId === null ? '' : String(selectedId);
    $('library-name').value = entry ? entry.name : '';
    $('library-published').checked = entry ? entry.published : false;
    $('library-delete').disabled = selectedId === null;
  }
  async function refresh() {
    entries = await request('configurations');
    $('library-list').replaceChildren(new Option('New configuration', ''));
    entries.forEach(entry => $('library-list').add(new Option(entry.name + ' · ' + entry.filename + (entry.published ? ' · published' : ' · draft'), entry.id)));
    $('library-list').value = selectedId === null ? '' : String(selectedId);
  }
  function busy(operation) {
    return async () => {
      $('library-save').disabled = true;
      try { await operation(); } catch (error) { message(error.message); }
      finally { $('library-save').disabled = false; }
    };
  }
  $('library-list').onchange = () => {
    const entry = entries.find(item => String(item.id) === $('library-list').value);
    selection(entry);
    if (entry) {
      applyConfig(entry.config);
      $('filename').value = entry.filename;
      message('Loaded ' + entry.name + '. Changes are saved only when you click Save to library.');
    } else {
      message('Save the current editor settings as a new configuration.');
    }
  };
  $('library-save').onclick = busy(async () => {
    const value = { name: $('library-name').value, filename: filename(), config: currentConfig(), published: $('library-published').checked };
    const entry = await request('configurations' + (selectedId === null ? '' : '/' + selectedId), {
      method: selectedId === null ? 'POST' : 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(value)
    });
    selectedId = entry.id;
    await refresh();
    selection(entry);
    message(entry.published ? 'Saved and exported to src/configurations/' + entry.filename + ' and dist/configurations/' + entry.filename + '. Commit and push to publish with GitHub Actions.' : 'Draft saved in SQLite. No JSON is published for this configuration.');
  });
  $('library-delete').onclick = busy(async () => {
    if (selectedId === null) return;
    const entry = entries.find(item => item.id === selectedId);
    if (!window.confirm('Delete ' + entry.name + ' and remove its published JSON, if any?')) return;
    await request('configurations/' + selectedId, { method: 'DELETE' });
    selection(null);
    await refresh();
    message('Configuration deleted. Commit and push to update the public distribution.');
  });
  async function init() {
    try {
      await refresh();
      $('library-controls').disabled = false;
      $('library-export').hidden = false;
      $('library-export').href = new URL('library.sqlite3', api);
      message('SQLite connected. Saved on this computer; publication runs after commit and push.');
    } catch {
      message('SQLite library requires the local server: run python3 src/generator_server.py and open http://127.0.0.1:8765/generator/. JSON import and download still work on static hosting.');
    }
  }
  init();
})();
