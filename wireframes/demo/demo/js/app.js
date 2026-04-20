/* =========================================================
   CASE DEMO — app.js  (fully functional: filters, search,
   data entry, print, tabs, modals, attendance)
   ========================================================= */

// ── STATE ──────────────────────────────────────────────────
let currentPage     = 'dashboard';
let activeProfileId = null;
let inquiries       = JSON.parse(JSON.stringify(INQUIRIES));
let studentFilter   = 'all';      // 'all' | 'sse' | 'nios' | room name
let studentSearch   = '';
let feeFilter       = 'all';      // 'all' | 'concessions' | 'overdue'
let staffFilter     = 'all';      // 'all' | 'educator' | 'therapist'
let currentDocFilter = 'all';
let attView         = 'mark';     // 'mark' | 'summary'
let attClass        = 'Rainbow Room';
let payTargetId     = null;

// ── NAVIGATION ─────────────────────────────────────────────
function nav(page, extra) {
  currentPage = page;
  document.querySelectorAll('.page').forEach(p => p.classList.remove('active'));
  document.querySelectorAll('.nav-item').forEach(n => n.classList.remove('active'));
  const pg = document.getElementById('pg-' + page);
  if (pg) pg.classList.add('active');
  const ni = document.querySelector(`.nav-item[data-page="${page}"]`);
  if (ni) ni.classList.add('active');

  const titles = {
    dashboard:'Dashboard', inquiries:'Inquiries & Intake',
    students:'Students', profile:'Child Profile',
    staff:'Staff & Educators', classes:'Classrooms',
    timetable:'Timetable', attendance:'Attendance',
    fees:'Fees & Concessions', documents:'Documents',
    notes:'Therapist Notes', hr:'HR & Staff', auth:'Roles & Access'
  };
  document.getElementById('page-title').textContent = titles[page] || page;

  const ctas = {
    dashboard:'+ New Inquiry', inquiries:'+ New Inquiry',
    students:'+ New Student Inquiry', profile:'← All Students',
    staff:'+ Add Staff', classes:'+ New Classroom',
    timetable:'🖨 Print Timetable', attendance:'💾 Save Attendance',
    fees:'+ Record Payment', documents:'+ Request Document',
    notes:'', hr:'+ Add Staff', auth:''
  };
  const ctaBtn = document.getElementById('topbar-cta');
  ctaBtn.textContent = ctas[page] || '';
  ctaBtn.style.display = (!ctas[page]) ? 'none' : 'inline-flex';

  if (page === 'profile' && extra) renderChildProfile(extra);
  if (page === 'dashboard')  renderDashboard();
  if (page === 'inquiries')  renderInquiries();
  if (page === 'students')   renderStudents();
  if (page === 'fees')       renderFees();
  if (page === 'documents')  renderDocuments();
  if (page === 'notes')      renderNotes();
  if (page === 'classes')    renderClasses();
  if (page === 'timetable')  renderTimetable();
  if (page === 'staff')      renderStaff();
  if (page === 'attendance') renderAttendance();
}

function ctaAction() {
  if (['dashboard','inquiries','students'].includes(currentPage)) openInquiryModal();
  if (currentPage === 'profile') nav('students');
  if (currentPage === 'timetable') printTimetable();
  if (currentPage === 'fees') openPaymentModal(null);
  if (currentPage === 'attendance') saveAttendance();
  if (currentPage === 'documents') showToast('Document request sent to parent contacts.','success');
}

// ── DASHBOARD ──────────────────────────────────────────────
function renderDashboard() {
  const pendingInq = inquiries.filter(i => ['new','assessment','review'].includes(i.stage)).length;
  const docsNeeded = STUDENTS.reduce((a,s) => a + s.docs.filter(d => d.status==='missing'||d.status==='pending').length, 0);
  const totalPaid  = STUDENTS.reduce((a,s) => a + s.feePaid, 0);
  const totalBal   = STUDENTS.reduce((a,s) => a + s.feeBalance, 0);

  document.getElementById('dash-students').textContent   = STUDENTS.length;
  document.getElementById('dash-classes').textContent    = CLASSES.length;
  document.getElementById('dash-inquiries').textContent  = pendingInq;
  document.getElementById('dash-fees').textContent       = STUDENTS.filter(s=>s.feeStatus!=='Paid').length;
  document.getElementById('dash-docs').textContent       = docsNeeded;
  document.getElementById('dash-fee-collected').textContent = '₹' + (totalPaid/1000).toFixed(0) + 'K';
  document.getElementById('dash-fee-pending').textContent   = '₹' + (totalBal/1000).toFixed(0) + 'K';

  document.getElementById('activity-feed').innerHTML = ACTIVITY_FEED.map(a => `
    <div class="activity-item">
      <div class="activity-icon" style="background:${a.iconBg}">${a.icon}</div>
      <div class="activity-text">${a.text}</div>
      <div class="activity-time">${a.time}</div>
    </div>`).join('');

  const sbm = {new:'badge-blue',assessment:'badge-amber',review:'badge-purple',admitted:'badge-green',rejected:'badge-gray'};
  const slm = {new:'New',assessment:'Assessment',review:'Under Review',admitted:'Admitted',rejected:'Not Admitted'};
  document.getElementById('dash-inquiries-list').innerHTML = inquiries.slice(0,4).map(i => `
    <div class="activity-item">
      <div class="activity-icon" style="background:#F0EDE6">👤</div>
      <div style="flex:1">
        <div class="font-bold text-sm">${i.childName}</div>
        <div class="text-xs text-muted">${i.disability} · ${i.parentName}</div>
      </div>
      <span class="badge ${sbm[i.stage]}">${slm[i.stage]}</span>
    </div>`).join('');
}

// ── INQUIRIES KANBAN ───────────────────────────────────────
function renderInquiries() {
  ['new','assessment','review','admitted','rejected'].forEach(stage => {
    const col   = document.getElementById('kanban-' + stage);
    const cnt   = document.getElementById('kanban-count-' + stage);
    if (!col) return;
    const cards = inquiries.filter(i => i.stage === stage);
    if (cnt) cnt.textContent = cards.length;
    col.innerHTML = cards.length === 0
      ? `<div class="text-xs text-muted" style="text-align:center;padding:20px">No inquiries here</div>`
      : cards.map(buildInquiryCard).join('');
  });
}

function buildInquiryCard(inq) {
  let actions = '';
  if (inq.stage === 'new')
    actions = `<button class="btn btn-sm btn-outline" onclick="moveInquiry('${inq.id}','assessment')">📅 Schedule Assessment</button>`;
  else if (inq.stage === 'assessment')
    actions = `<button class="btn btn-sm btn-primary" onclick="moveInquiry('${inq.id}','review')">✅ Mark Assessed</button>`;
  else if (inq.stage === 'review')
    actions = `<button class="btn btn-sm btn-success" onclick="admitInquiry('${inq.id}')">✅ Admit</button>
               <button class="btn btn-sm btn-danger" onclick="moveInquiry('${inq.id}','rejected')">✗ Not Fit</button>`;
  return `
    <div class="kanban-card">
      <div class="kanban-card-name">${inq.childName}</div>
      <div class="kanban-card-meta">${inq.disability} · Age ${inq.age}<br>Parent: ${inq.parentName}<br>📞 ${inq.contact} · 📅 ${inq.date}</div>
      ${inq.notes ? `<div style="font-size:11px;color:var(--text2);background:var(--surface2);border-radius:4px;padding:6px 8px;margin-bottom:8px;line-height:1.5">${inq.notes}</div>`:''}
      <div class="kanban-card-actions">${actions}</div>
    </div>`;
}

function moveInquiry(id, stage) {
  const inq = inquiries.find(i => i.id === id);
  if (!inq) return;
  inq.stage = stage;
  if (stage === 'assessment') inq.assessmentDate = 'Apr 25, 2025';
  renderInquiries();
  updateInquiryBadge();
  showToast(`${inq.childName} moved to "${stage.replace(/_/g,' ')}".`, 'success');
}

function admitInquiry(id) {
  const inq = inquiries.find(i => i.id === id);
  if (!inq) return;
  inq.stage = 'admitted';
  renderInquiries();
  updateInquiryBadge();
  showToast(`${inq.childName} admitted. Student record created.`, 'success');
}

function updateInquiryBadge() {
  const n = inquiries.filter(i => ['new','assessment','review'].includes(i.stage)).length;
  const b = document.getElementById('inq-badge');
  if (b) b.textContent = n;
}

// ── STUDENTS (live search + tab filter) ────────────────────
function renderStudents(filter, search) {
  if (filter !== undefined) studentFilter = filter;
  if (search  !== undefined) studentSearch  = search;

  // Update active tab
  document.querySelectorAll('.stu-tab').forEach(b => b.classList.remove('active'));
  const activeTab = document.querySelector(`.stu-tab[data-filter="${studentFilter}"]`);
  if (activeTab) activeTab.classList.add('active');

  let data = [...STUDENTS];

  // Tab filter
  if (studentFilter === 'sse')  data = data.filter(s => s.boardTrack.includes('SSE'));
  if (studentFilter === 'nios') data = data.filter(s => s.boardTrack.includes('NIOS'));
  if (!['all','sse','nios'].includes(studentFilter)) data = data.filter(s => s.room === studentFilter);

  // Live search
  if (studentSearch.trim()) {
    const q = studentSearch.toLowerCase();
    data = data.filter(s =>
      s.name.toLowerCase().includes(q) ||
      s.id.toLowerCase().includes(q) ||
      s.disability.toLowerCase().includes(q) ||
      s.room.toLowerCase().includes(q) ||
      s.boardTrack.toLowerCase().includes(q)
    );
  }

  const tbody = document.getElementById('student-tbody');
  if (data.length === 0) {
    tbody.innerHTML = `<tr><td colspan="8"><div class="empty-state"><div class="empty-icon">🔍</div>No students match your filter.</div></td></tr>`;
    return;
  }

  tbody.innerHTML = data.map(s => {
    const trackCls = s.boardTrack.includes('SSE') ? 'badge-blue' : 'badge-purple';
    const missing  = s.docs.filter(d => d.status === 'missing').length;
    return `<tr>
      <td>
        <div class="flex items-center gap-8">
          <div class="avatar avatar-sm" style="background:${s.color}">${s.avatar}</div>
          <div><div class="font-bold text-sm">${s.name}</div><div class="text-xs text-muted">${s.disability}</div></div>
        </div>
      </td>
      <td class="font-mono" style="font-size:11px">${s.id}</td>
      <td>${s.room}</td>
      <td style="font-size:12px">${s.educator}</td>
      <td><span class="badge ${trackCls}">${s.boardTrack}</span></td>
      <td><span class="badge badge-gray">${s.classLevel}</span></td>
      <td style="font-size:12px">${s.enrolledDate}</td>
      <td>
        ${missing > 0 ? `<span class="badge badge-red" style="display:block;margin-bottom:4px">${missing} doc missing</span>` : ''}
        <div class="flex gap-6">
          <button class="btn btn-sm btn-outline" onclick="nav('profile','${s.id}')">View Profile</button>
        </div>
      </td>
    </tr>`;
  }).join('');

  document.getElementById('student-count').textContent = `Showing ${data.length} of ${STUDENTS.length} students`;
}

function searchStudents(q) { renderStudents(undefined, q); }
function filterStudentTab(f) { renderStudents(f, studentSearch); }

// ── CHILD PROFILE ──────────────────────────────────────────
function renderChildProfile(studentId) {
  activeProfileId = studentId;
  const s = STUDENTS.find(st => st.id === studentId);
  if (!s) return;

  document.getElementById('profile-name').textContent = s.name;
  document.getElementById('profile-avatar-text').textContent = s.avatar;
  document.getElementById('profile-avatar').style.background = s.color;
  document.getElementById('profile-meta').textContent = `${s.id}  ·  Age ${s.age}  ·  DOB: ${s.dob}  ·  Enrolled: ${s.enrolledDate}`;
  document.getElementById('profile-track-tag').textContent = s.boardTrack;
  document.getElementById('profile-level-tag').textContent = s.classLevel;
  document.getElementById('profile-status-tag').textContent = s.status;

  document.getElementById('pf-disability').textContent   = s.disability;
  document.getElementById('pf-certdate').textContent     = s.certDate;
  document.getElementById('pf-certboard').textContent    = s.certBoard;
  document.getElementById('pf-concession').textContent   = s.concession;
  document.getElementById('pf-conc-reason').textContent  = s.concessionReason;
  document.getElementById('pf-conc-status').innerHTML    = `<span class="badge badge-green">${s.concessionStatus}</span>`;
  document.getElementById('pf-room').textContent         = s.room;
  document.getElementById('pf-educator').textContent     = s.educator;
  document.getElementById('pf-parent').textContent       = s.parent;
  document.getElementById('pf-contact').textContent      = s.contact;
  document.getElementById('pf-fee-status').innerHTML     = `<span class="badge ${s.feeStatus==='Paid'?'badge-green':s.feeStatus==='Overdue'?'badge-red':'badge-amber'}">${s.feeStatus} ${s.feeBalance>0?'(₹'+s.feeBalance.toLocaleString()+' due)':''}</span>`;
  document.getElementById('pf-donation').textContent     = s.donationFunded ? '✅ Yes — Fee Subsidised' : 'No';

  profileTab('overview');
  renderProfileDocs(s);
  renderProfileNotes(s);
}

// FIX: use direct IDs, not class selector
function profileTab(tab) {
  document.querySelectorAll('.profile-tab-btn').forEach(b => b.classList.remove('active'));
  const btn = document.querySelector(`.profile-tab-btn[data-tab="${tab}"]`);
  if (btn) btn.classList.add('active');
  ['overview','docs','notes'].forEach(t => {
    const el = document.getElementById('ptab-' + t);
    if (el) el.style.display = (t === tab) ? 'block' : 'none';
  });
}

function renderProfileDocs(s) {
  const tbody = document.getElementById('profile-docs-tbody');
  tbody.innerHTML = s.docs.map((d, idx) => {
    const cls   = {verified:'doc-status-verified', pending:'doc-status-pending', missing:'doc-status-missing', uploaded:'doc-status-uploaded'}[d.status];
    const label = {verified:'✓ Verified', pending:'⏳ Pending Upload', missing:'✗ Missing', uploaded:'📤 Uploaded'}[d.status];
    const action = (d.status==='missing'||d.status==='pending')
      ? `<button class="btn btn-sm btn-primary" onclick="fakeUpload('${s.id}',${idx})">📎 Upload</button>`
      : `<button class="btn btn-sm btn-ghost" onclick="showToast('Opening ${d.file}…','success')">📥 View</button>`;
    return `<tr id="doc-row-${s.id}-${idx}">
      <td class="font-bold text-sm">${d.name}</td>
      <td><span class="badge badge-gray">${d.type}</span></td>
      <td><span class="badge badge-blue">${d.board}</span></td>
      <td><span class="${cls}">${label}</span></td>
      <td class="text-xs text-muted">${d.date}</td>
      <td>${action}</td>
    </tr>`;
  }).join('');

  const missing = s.docs.filter(d => d.status==='missing').length;
  const pending = s.docs.filter(d => d.status==='pending').length;
  const ready   = s.docs.length - missing - pending;
  const isReady = missing === 0;
  document.getElementById('board-readiness').innerHTML = `
    <div class="flex items-center gap-12" style="padding:14px 16px;background:${isReady?'#E8F7EF':'#FEF3E2'};border-radius:var(--radius-sm);border:1px solid ${isReady?'#b5e0ca':'#f0c98a'}">
      <span style="font-size:22px">${isReady?'✅':'⚠️'}</span>
      <div>
        <div class="font-bold text-sm">${isReady?'Board Documents Complete':'Documents Incomplete'}</div>
        <div class="text-xs text-muted">${ready} of ${s.docs.length} complete · ${missing} missing · ${pending} pending upload</div>
      </div>
      <div class="flex gap-6 ml-auto">
        ${missing>0?`<button class="btn btn-sm btn-primary" onclick="showToast('Document request sent to ${s.parent}.','success')">Request Missing</button>`:''}
        <button class="btn btn-sm btn-outline" onclick="printDocChecklist('${s.id}')">🖨 Print Checklist</button>
      </div>
    </div>`;
}

function renderProfileNotes(s) {
  const list = document.getElementById('profile-notes-list');
  if (!s.notes.length) {
    list.innerHTML = '<div class="empty-state"><div class="empty-icon">📝</div>No notes yet. Add the first note.</div>';
    return;
  }
  list.innerHTML = s.notes.map((n, idx) => `
    <div class="note-item">
      <div class="note-line">
        <div class="note-dot" style="background:${n.tag.includes('green')?'var(--accent3)':n.tag.includes('amber')?'var(--accent2)':n.tag.includes('red')?'var(--danger)':'var(--accent)'}"></div>
        ${idx < s.notes.length-1 ? '<div class="note-connector"></div>' : ''}
      </div>
      <div class="note-body">
        <div class="note-header">
          <span class="note-author">${n.by} <span class="text-xs text-muted" style="font-weight:400">(${n.role})</span></span>
          <span class="note-time">${n.date}</span>
        </div>
        <div class="note-text">${n.text}</div>
        <span class="note-tag badge ${n.tag}">${n.type}</span>
      </div>
    </div>`).join('');
}

function fakeUpload(studentId, docIdx) {
  const s = STUDENTS.find(st => st.id === studentId);
  if (!s) return;
  const d    = s.docs[docIdx];
  d.status   = 'uploaded';
  d.date     = 'Apr 20, 2025';
  d.file     = `${d.name.replace(/\s+/g,'_')}_${studentId}.pdf`;
  if (activeProfileId === studentId) renderProfileDocs(s);
  renderDocuments(currentDocFilter);
  showToast(`"${d.name}" uploaded successfully.`, 'success');
}

function addNoteToProfile() {
  const s = STUDENTS.find(st => st.id === activeProfileId);
  if (!s) return;
  const role = document.getElementById('note-role').value;
  const type = document.getElementById('note-type').value;
  const text = document.getElementById('note-text').value.trim();
  if (!text) { showToast('Please enter a note before saving.', 'error'); return; }
  const tagMap = {Progress:'badge-green', Concern:'badge-amber', 'Behavioral Concern':'badge-red', Observation:'badge-blue'};
  s.notes.unshift({ by: role.split(' (')[0], role: (role.split(' (')[1]||'').replace(')',''), date:'Apr 20, 2025', type, text, tag: tagMap[type]||'badge-blue' });
  renderProfileNotes(s);
  document.getElementById('note-text').value = '';
  showToast('Note saved successfully.', 'success');
}

// ── CLASSES ────────────────────────────────────────────────
function renderClasses() {
  document.getElementById('classes-grid').innerHTML = CLASSES.map(cls => {
    const students = STUDENTS.filter(s => cls.studentIds.includes(s.id));
    const pct = Math.round((students.length / cls.capacity) * 100);
    const fillColor = pct >= 100 ? 'var(--accent2)' : pct >= 80 ? 'var(--accent)' : 'var(--accent3)';
    return `
      <div class="card">
        <div class="card-header" style="background:linear-gradient(135deg,var(--surface2),var(--bg))">
          <div>
            <div class="card-title">${cls.icon} ${cls.name}</div>
            <div class="text-xs text-muted" style="margin-top:3px">${cls.level} · ${cls.track}</div>
          </div>
          <span class="badge badge-blue">${students.length} / ${cls.capacity} seats</span>
        </div>
        <div class="card-body">
          <div class="text-xs text-muted mb-8">Educator: <strong style="color:var(--text)">${cls.educator}</strong></div>
          <div class="text-xs text-muted mb-16">⏰ ${cls.timing}</div>
          <div style="display:flex;flex-direction:column;gap:8px;margin-bottom:16px">
            ${students.map(s => `
              <div class="flex items-center gap-8">
                <div class="avatar avatar-sm" style="background:${s.color}">${s.avatar}</div>
                <div style="flex:1">
                  <div class="text-sm font-bold">${s.name}</div>
                  <div class="text-xs text-muted">${s.boardTrack} · ${s.classLevel}</div>
                </div>
                <button class="btn btn-sm btn-ghost" onclick="nav('profile','${s.id}')">View</button>
              </div>`).join('')}
          </div>
          <div class="progress"><div class="progress-bar" style="width:${pct}%;background:${fillColor}"></div></div>
          <div class="text-xs text-muted mt-8">${pct}% capacity · ${cls.capacity-students.length} seat(s) open</div>
          <div class="hr-bar"></div>
          <div class="text-xs text-muted" style="line-height:1.6">${cls.desc}</div>
        </div>
      </div>`;
  }).join('');
}

// ── TIMETABLE ──────────────────────────────────────────────
let activeTTClass = 'Rainbow Room';
function renderTimetable() {
  document.getElementById('tt-class-tabs').innerHTML = CLASSES.map(c =>
    `<button class="tab-btn ${c.name===activeTTClass?'active':''}" onclick="switchTTClass('${c.name}')">${c.icon} ${c.name}</button>`
  ).join('');
  buildTimetableGrid(activeTTClass);
}
function switchTTClass(name) { activeTTClass = name; renderTimetable(); }
function buildTimetableGrid(className) {
  const tt   = TIMETABLE[className];
  const days = ['Mon','Tue','Wed','Thu','Fri'];
  let html   = `<table class="timetable"><thead><tr><th style="width:100px">Time</th>${days.map(d=>`<th>${d}</th>`).join('')}</tr></thead><tbody>`;
  Object.keys(tt).forEach(slot => {
    html += `<tr><td style="background:var(--surface2);text-align:center;font-size:10px;font-weight:600;color:var(--text3);padding:8px;white-space:nowrap">${slot}</td>`;
    days.forEach(day => {
      const subj = tt[slot][day];
      if (subj === '— Break —' || subj === '— Lunch —') {
        html += `<td><div class="tt-empty" style="text-align:center;padding:18px 0;color:var(--text3);font-size:11px">${subj}</div></td>`;
      } else {
        const cc = SUBJECT_COLORS[subj] || 'tt-blue';
        html += `<td><div class="tt-slot ${cc}"><div class="tt-period">${className}</div><div class="tt-class">${subj}</div></div></td>`;
      }
    });
    html += '</tr>';
  });
  html += '</tbody></table>';
  document.getElementById('timetable-grid').innerHTML = html;
}
function printTimetable() {
  const cls = CLASSES.find(c => c.name === activeTTClass);
  const tt  = TIMETABLE[activeTTClass];
  const days = ['Mon','Tue','Wed','Thu','Fri'];
  let rows = '';
  Object.keys(tt).forEach(slot => {
    rows += `<tr><td style="font-weight:bold;background:#f5f5f5;padding:6px 10px;white-space:nowrap">${slot}</td>`;
    days.forEach(day => {
      const subj = tt[slot][day];
      const bg = (subj==='— Break —'||subj==='— Lunch —') ? '#f9f9f9' : '#fff';
      rows += `<td style="padding:8px;border:1px solid #e0e0e0;background:${bg};font-size:12px">${subj}</td>`;
    });
    rows += '</tr>';
  });
  const win = window.open('','_blank','width=900,height=600');
  win.document.write(`<!DOCTYPE html><html><head><title>Timetable — ${activeTTClass}</title>
    <style>body{font-family:Arial,sans-serif;padding:24px}table{border-collapse:collapse;width:100%}th,td{border:1px solid #ccc;padding:8px}th{background:#1C2B3A;color:#fff}h2{color:#1C2B3A}p{color:#666;font-size:13px}@media print{button{display:none}}</style>
    </head><body>
    <h2>CASE — Centre for Autism & Special Education</h2>
    <p><strong>Class:</strong> ${activeTTClass} &nbsp;|&nbsp; <strong>Track:</strong> ${cls.track} &nbsp;|&nbsp; <strong>Educator:</strong> ${cls.educator} &nbsp;|&nbsp; <strong>Timing:</strong> ${cls.timing}</p>
    <table><thead><tr><th>Time</th>${days.map(d=>`<th>${d}</th>`).join('')}</tr></thead><tbody>${rows}</tbody></table>
    <br><button onclick="window.print()" style="padding:8px 20px;background:#1C2B3A;color:#fff;border:none;border-radius:6px;cursor:pointer;font-size:14px">🖨 Print</button>
    </body></html>`);
  win.document.close();
}

// ── ATTENDANCE ─────────────────────────────────────────────
const ATT_DATA = {
  'Rainbow Room': [
    {id:'CASE-001', name:'Arjun Sharma',  avatar:'AS', color:'#2E7D9F', board:'SSE', days:[1,1,1,1,0,1,1,1,1,2,1,1,1,1,0,1,1,1,0,1]},
    {id:'CASE-002', name:'Riya Patel',    avatar:'RP', color:'#E8913A', board:'NIOS', days:[1,1,1,1,1,1,1,0,1,1,1,1,1,1,1,1,1,1,1,1]},
    {id:'CASE-007', name:'Meera Gupta',   avatar:'MG', color:'#4CAF7D', board:'NIOS', days:[1,1,0,1,1,1,1,1,1,1,1,0,1,1,1,1,1,1,1,1]},
    {id:'CASE-010', name:'Aarav Verma',   avatar:'AV', color:'#9B59B6', board:'SSE',  days:[1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1]},
  ]
};
// 0=absent, 1=present, 2=late
const ATT_DAYS = ['Apr 1','Apr 2','Apr 3','Apr 4','Apr 7','Apr 8','Apr 9','Apr 10','Apr 11','Apr 14','Apr 15','Apr 16','Apr 17','Apr 18','Apr 21','Apr 22','Apr 23','Apr 24','Apr 25','Apr 28'];
const ATT_COLOR = {1:'#E8F7EF',0:'#FDEAEA',2:'#FEF3E2',null:'#F0EDE6'};
const ATT_SYMBOL = {1:'P',0:'A',2:'L',null:'-'};

function renderAttendance() {
  switchAttView(attView);
  // Wire classroom selector
  const sel = document.getElementById('att-class-select');
  if (sel) { sel.value = attClass; sel.onchange = () => { attClass = sel.value; renderAttendanceContent(); }; }
}
function switchAttView(view) {
  attView = view;
  document.querySelectorAll('.att-tab').forEach(b => b.classList.remove('active'));
  const tb = document.querySelector(`.att-tab[data-view="${view}"]`);
  if (tb) tb.classList.add('active');
  document.getElementById('att-mark-section').style.display = view === 'mark' ? 'block' : 'none';
  document.getElementById('att-summary-section').style.display = view === 'summary' ? 'block' : 'none';
  if (view === 'summary') renderAttendanceSummary();
}
function renderAttendanceContent() { if (attView === 'summary') renderAttendanceSummary(); }
function renderAttendanceSummary() {
  const classData = ATT_DATA['Rainbow Room']; // demo uses Rainbow Room
  const container = document.getElementById('att-summary-grid');
  container.innerHTML = classData.map(stu => {
    const present = stu.days.filter(d=>d===1).length;
    const absent  = stu.days.filter(d=>d===0).length;
    const late    = stu.days.filter(d=>d===2).length;
    const pct     = Math.round((present/stu.days.length)*100);
    const dayCells = ATT_DAYS.map((day,i) => {
      const v = stu.days[i] !== undefined ? stu.days[i] : null;
      return `<div title="${day}" style="width:22px;height:22px;border-radius:3px;background:${ATT_COLOR[v]};display:flex;align-items:center;justify-content:center;font-size:9px;font-weight:700;color:${v===1?'#2D8A58':v===0?'#D95C5C':v===2?'#B36B18':'#aaa'}">${ATT_SYMBOL[v]}</div>`;
    }).join('');
    return `
      <div class="card mb-16">
        <div class="card-body" style="padding:14px 18px">
          <div class="flex items-center gap-12" style="margin-bottom:12px">
            <div class="avatar avatar-sm" style="background:${stu.color}">${stu.avatar}</div>
            <div style="flex:1">
              <div class="font-bold text-sm">${stu.name}</div>
              <div class="text-xs text-muted">${stu.board} Board</div>
            </div>
            <div style="text-align:right">
              <div style="font-family:'DM Serif Display',serif;font-size:22px;color:${pct>=80?'var(--accent3)':pct>=60?'var(--accent2)':'var(--danger)'}">${pct}%</div>
              <div class="text-xs text-muted">Present</div>
            </div>
            <div style="display:grid;grid-template-columns:repeat(3,1fr);gap:6px;text-align:center">
              <div style="background:var(--surface2);border-radius:4px;padding:6px 10px"><div style="font-weight:700;color:var(--accent3)">${present}</div><div class="text-xs text-muted">P</div></div>
              <div style="background:var(--surface2);border-radius:4px;padding:6px 10px"><div style="font-weight:700;color:var(--danger)">${absent}</div><div class="text-xs text-muted">A</div></div>
              <div style="background:var(--surface2);border-radius:4px;padding:6px 10px"><div style="font-weight:700;color:var(--accent2)">${late}</div><div class="text-xs text-muted">L</div></div>
            </div>
          </div>
          <div class="text-xs text-muted mb-8" style="font-weight:600;letter-spacing:0.3px;text-transform:uppercase">April 2025 — Day-wise Record</div>
          <div style="display:flex;gap:3px;flex-wrap:wrap">${dayCells}</div>
          <div style="display:flex;gap:12px;margin-top:8px">
            <span style="font-size:10px;display:flex;align-items:center;gap:4px"><span style="width:10px;height:10px;border-radius:2px;background:#E8F7EF;display:inline-block"></span>Present</span>
            <span style="font-size:10px;display:flex;align-items:center;gap:4px"><span style="width:10px;height:10px;border-radius:2px;background:#FDEAEA;display:inline-block"></span>Absent</span>
            <span style="font-size:10px;display:flex;align-items:center;gap:4px"><span style="width:10px;height:10px;border-radius:2px;background:#FEF3E2;display:inline-block"></span>Late</span>
          </div>
        </div>
      </div>`;
  }).join('');
}
function markAttendance(btn, status) {
  const row = btn.closest('tr');
  row.querySelectorAll('.att-btn').forEach(b => { b.classList.remove('btn-primary','btn-danger','btn-amber'); b.classList.add('btn-ghost'); });
  btn.classList.remove('btn-ghost');
  if (status==='present') btn.classList.add('btn-primary');
  else if (status==='absent') btn.classList.add('btn-danger');
  else btn.classList.add('btn-amber');
}
function saveAttendance() {
  const sel = document.getElementById('att-class-select');
  const room = sel ? sel.value : 'Rainbow Room';
  const dateEl = document.getElementById('att-date');
  const date = dateEl ? dateEl.value : 'Apr 20, 2025';
  showToast(`Attendance saved for ${room} — ${date}.`, 'success');
}

// ── FEES (tab filter + payment modal) ──────────────────────
function renderFees(filter) {
  if (filter !== undefined) feeFilter = filter;

  document.querySelectorAll('.fee-tab').forEach(b => b.classList.remove('active'));
  const ft = document.querySelector(`.fee-tab[data-filter="${feeFilter}"]`);
  if (ft) ft.classList.add('active');

  let data = [...STUDENTS];
  if (feeFilter === 'concessions') data = data.filter(s => s.donationFunded || s.concessionReason.includes('Economic'));
  if (feeFilter === 'overdue')     data = data.filter(s => s.feeStatus === 'Overdue' || s.feeStatus === 'Partial');

  const totFee = data.reduce((a,s) => a+s.termFee, 0);
  const totPaid = data.reduce((a,s) => a+s.feePaid, 0);
  const totBal  = data.reduce((a,s) => a+s.feeBalance, 0);

  document.getElementById('fees-total').textContent       = '₹' + (totFee/1000).toFixed(0) + 'K';
  document.getElementById('fees-collected').textContent   = '₹' + (totPaid/1000).toFixed(0) + 'K';
  document.getElementById('fees-pending').textContent     = '₹' + (totBal/1000).toFixed(0) + 'K';
  document.getElementById('fees-concessions').textContent = STUDENTS.filter(s => s.donationFunded || s.concessionReason.includes('Economic')).length;

  if (data.length === 0) {
    document.getElementById('fees-tbody').innerHTML = `<tr><td colspan="7"><div class="empty-state"><div class="empty-icon">💳</div>No records match this filter.</div></td></tr>`;
    return;
  }

  document.getElementById('fees-tbody').innerHTML = data.map(s => {
    const fc = s.feeStatus==='Paid' ? 'badge-green' : s.feeStatus==='Overdue' ? 'badge-red' : 'badge-amber';
    const rc = s.donationFunded ? 'concession-row' : '';
    return `<tr class="${rc}">
      <td>
        <div class="flex items-center gap-8">
          <div class="avatar avatar-sm" style="background:${s.color}">${s.avatar}</div>
          <div><div class="font-bold text-sm">${s.name}</div><div class="text-xs text-muted">${s.room}</div></div>
        </div>
      </td>
      <td>₹${s.termFee.toLocaleString()}</td>
      <td>${s.donationFunded
        ? `<span class="badge badge-green">Donation Funded</span><br><span class="text-xs text-muted">${s.concessionReason}</span>`
        : s.concessionReason.includes('Economic')
          ? `<span class="badge badge-amber">Economic Background</span><br><span class="text-xs text-muted">${s.concession}</span>`
          : `<span class="text-xs text-muted">${s.concession}</span>`}
      </td>
      <td style="font-weight:600;color:var(--accent3)">₹${s.feePaid.toLocaleString()}</td>
      <td style="font-weight:600;color:${s.feeBalance>0?'var(--danger)':'var(--text3)'}">
        ${s.feeBalance>0 ? '₹'+s.feeBalance.toLocaleString() : '—'}
      </td>
      <td><span class="badge ${fc}">${s.feeStatus}</span></td>
      <td>
        ${s.feeStatus !== 'Paid'
          ? `<button class="btn btn-sm btn-primary" onclick="openPaymentModal('${s.id}')">+ Record</button>`
          : `<button class="btn btn-sm btn-outline" onclick="printFeeReceipt('${s.id}')">🖨 Receipt</button>`}
      </td>
    </tr>`;
  }).join('');
}

// Payment modal
function openPaymentModal(studentId) {
  if (!studentId) {
    // Open generic — pick student
    payTargetId = null;
    document.getElementById('pay-student-row').style.display = 'block';
    document.getElementById('pay-info-row').style.display    = 'none';
    const psel = document.getElementById('pay-student-select');
    psel.innerHTML = '<option value="">— Select Student —</option>' +
      STUDENTS.filter(s => s.feeStatus !== 'Paid').map(s =>
        `<option value="${s.id}">${s.name} (Balance: ₹${s.feeBalance.toLocaleString()})</option>`).join('');
    psel.onchange = () => prefillPayment(psel.value);
    document.getElementById('pay-amount').value = '';
  } else {
    payTargetId = studentId;
    document.getElementById('pay-student-row').style.display = 'none';
    document.getElementById('pay-info-row').style.display    = 'block';
    prefillPayment(studentId);
  }
  document.getElementById('pay-modal').style.display = 'flex';
}
function prefillPayment(id) {
  payTargetId = id;
  if (!id) return;
  const s = STUDENTS.find(st => st.id === id);
  if (!s) return;
  document.getElementById('pay-student-name').textContent = s.name;
  document.getElementById('pay-balance-show').textContent = '₹' + s.feeBalance.toLocaleString();
  document.getElementById('pay-amount').value = s.feeBalance;
  document.getElementById('pay-date').value = '2025-04-20';
}
function closePayModal() { document.getElementById('pay-modal').style.display = 'none'; }
function submitPayment() {
  const id = payTargetId || document.getElementById('pay-student-select')?.value;
  if (!id) { showToast('Please select a student.','error'); return; }
  const s      = STUDENTS.find(st => st.id === id);
  const amount = parseInt(document.getElementById('pay-amount').value);
  const mode   = document.getElementById('pay-mode').value;
  const ref    = document.getElementById('pay-ref').value.trim();
  if (!amount || amount <= 0)     { showToast('Enter a valid amount.','error'); return; }
  if (amount > s.feeBalance)      { showToast('Amount exceeds outstanding balance.','error'); return; }
  s.feePaid    += amount;
  s.feeBalance -= amount;
  s.feeStatus   = s.feeBalance === 0 ? 'Paid' : 'Partial';
  closePayModal();
  renderFees();
  showToast(`₹${amount.toLocaleString()} recorded for ${s.name} via ${mode}. ${s.feeBalance===0?'Account cleared.':'Balance: ₹'+s.feeBalance.toLocaleString()}`, 'success');
}

// ── DOCUMENTS (filter tabs + live search) ──────────────────
function renderDocuments(filter) {
  if (filter !== undefined) currentDocFilter = filter;

  document.querySelectorAll('.docs-filter-btn').forEach(b => b.classList.remove('active'));
  const db = document.querySelector(`.docs-filter-btn[data-filter="${currentDocFilter}"]`);
  if (db) db.classList.add('active');

  const docSearch = (document.getElementById('doc-search')?.value || '').toLowerCase();

  let docs = [];
  STUDENTS.forEach(s => s.docs.forEach((d,idx) =>
    docs.push({...d, studentName:s.name, studentId:s.id, docIdx:idx, studentColor:s.color, studentAvatar:s.avatar})
  ));

  if (currentDocFilter==='missing') docs = docs.filter(d => d.status==='missing');
  if (currentDocFilter==='pending') docs = docs.filter(d => d.status==='pending');
  if (currentDocFilter==='verified') docs = docs.filter(d => d.status==='verified');
  if (currentDocFilter==='board')   docs = docs.filter(d => d.type==='Board Form');

  if (docSearch) docs = docs.filter(d =>
    d.studentName.toLowerCase().includes(docSearch) ||
    d.name.toLowerCase().includes(docSearch) ||
    d.type.toLowerCase().includes(docSearch)
  );

  document.getElementById('docs-count').textContent = `${docs.length} document${docs.length!==1?'s':''}`;

  const tbody = document.getElementById('docs-tbody');
  if (!docs.length) {
    tbody.innerHTML = `<tr><td colspan="7"><div class="empty-state"><div class="empty-icon">📂</div>No documents match this filter.</div></td></tr>`;
    return;
  }
  const cls   = {verified:'doc-status-verified', pending:'doc-status-pending', missing:'doc-status-missing', uploaded:'doc-status-uploaded'};
  const label = {verified:'✓ Verified', pending:'⏳ Pending', missing:'✗ Missing', uploaded:'📤 Uploaded'};
  tbody.innerHTML = docs.map(d => `
    <tr>
      <td>
        <div class="flex items-center gap-8">
          <div class="avatar avatar-sm" style="background:${d.studentColor}">${d.studentAvatar}</div>
          <span class="font-bold text-sm">${d.studentName}</span>
        </div>
      </td>
      <td>${d.name}</td>
      <td><span class="badge badge-gray">${d.type}</span></td>
      <td><span class="badge badge-blue">${d.board}</span></td>
      <td><span class="${cls[d.status]||''}">${label[d.status]||d.status}</span></td>
      <td class="text-xs text-muted">${d.date}</td>
      <td>
        ${(d.status==='missing'||d.status==='pending')
          ? `<button class="btn btn-sm btn-primary" onclick="fakeUpload('${d.studentId}',${d.docIdx})">📎 Upload</button>`
          : `<button class="btn btn-sm btn-ghost" onclick="showToast('Opening ${d.file}…','success')">View</button>`}
        <button class="btn btn-sm btn-outline" style="margin-left:4px" onclick="nav('profile','${d.studentId}');profileTab('docs')">Profile</button>
      </td>
    </tr>`).join('');
}
function filterDocs(filter) { renderDocuments(filter); }
function searchDocs(q) { renderDocuments(currentDocFilter); }

// ── THERAPIST NOTES ────────────────────────────────────────
let notesFilter = 'all';
function renderNotes(filter) {
  if (filter !== undefined) notesFilter = filter;
  document.querySelectorAll('.notes-tab').forEach(b => b.classList.remove('active'));
  const nt = document.querySelector(`.notes-tab[data-filter="${notesFilter}"]`);
  if (nt) nt.classList.add('active');

  let all = [];
  STUDENTS.forEach(s => s.notes.forEach(n => all.push({...n, studentName:s.name, studentId:s.id, studentColor:s.color, studentAvatar:s.avatar})));
  all.sort((a,b) => new Date(b.date)-new Date(a.date));

  if (notesFilter === 'progress')  all = all.filter(n => n.type === 'Progress');
  if (notesFilter === 'concern')   all = all.filter(n => n.type === 'Concern' || n.type === 'Behavioral Concern');
  if (notesFilter === 'speech')    all = all.filter(n => n.role.includes('Speech'));
  if (notesFilter === 'ot')        all = all.filter(n => n.role.includes('Occupational'));

  const list = document.getElementById('notes-list');
  if (!all.length) {
    list.innerHTML = '<div class="empty-state"><div class="empty-icon">📝</div>No notes match this filter.</div>';
    return;
  }
  list.innerHTML = all.map((n,idx) => `
    <div class="note-item">
      <div class="note-line">
        <div class="note-dot" style="background:${n.tag.includes('green')?'var(--accent3)':n.tag.includes('amber')?'var(--accent2)':n.tag.includes('red')?'var(--danger)':'var(--accent)'}"></div>
        ${idx < all.length-1 ? '<div class="note-connector"></div>' : ''}
      </div>
      <div class="note-body">
        <div class="note-header">
          <div class="flex items-center gap-8">
            <div class="avatar avatar-sm" style="background:${n.studentColor}">${n.studentAvatar}</div>
            <span class="font-bold text-sm">${n.studentName}</span>
            <span class="badge ${n.tag}">${n.type}</span>
          </div>
          <span class="note-time">${n.date}</span>
        </div>
        <div style="font-size:11px;color:var(--text3);margin:4px 0 6px">${n.by} · ${n.role}</div>
        <div class="note-text">${n.text}</div>
        <button class="btn btn-sm btn-ghost" style="margin-top:8px" onclick="nav('profile','${n.studentId}');profileTab('notes')">View Student Profile →</button>
      </div>
    </div>`).join('');
}

function submitNote() {
  const studentId = document.getElementById('add-note-student').value;
  const role      = document.getElementById('add-note-role').value;
  const type      = document.getElementById('add-note-type').value;
  const text      = document.getElementById('add-note-text').value.trim();
  if (!studentId)  { showToast('Please select a student.','error'); return; }
  if (!text)       { showToast('Please enter a note.','error'); return; }
  const s = STUDENTS.find(st => st.id === studentId);
  const tagMap = {Progress:'badge-green', Concern:'badge-amber', 'Behavioral Concern':'badge-red', Observation:'badge-blue'};
  s.notes.unshift({ by:role.split(' (')[0], role:(role.split(' (')[1]||'').replace(')',''), date:'Apr 20, 2025', type, text, tag:tagMap[type]||'badge-blue' });
  document.getElementById('add-note-text').value = '';
  renderNotes(notesFilter);
  showToast(`Note saved for ${s.name}.`, 'success');
}

// ── STAFF ──────────────────────────────────────────────────
function renderStaff(filter) {
  if (filter !== undefined) staffFilter = filter;
  document.querySelectorAll('.staff-tab').forEach(b => b.classList.remove('active'));
  const st = document.querySelector(`.staff-tab[data-filter="${staffFilter}"]`);
  if (st) st.classList.add('active');

  let data = [...STAFF];
  if (staffFilter === 'educator')  data = data.filter(s => s.dept === 'Special Education');
  if (staffFilter === 'therapist') data = data.filter(s => s.dept === 'Therapy');
  if (staffFilter === 'admin')     data = data.filter(s => s.dept === 'Administration');

  document.getElementById('staff-tbody').innerHTML = data.map(s => `
    <tr>
      <td>
        <div class="flex items-center gap-8">
          <div class="avatar avatar-sm" style="background:${s.color}">${s.avatar}</div>
          <div><div class="font-bold text-sm">${s.name}</div><div class="text-xs text-muted">${s.designation}</div></div>
        </div>
      </td>
      <td class="font-mono" style="font-size:11px">${s.id}</td>
      <td>${s.dept}</td>
      <td>${s.specs.map(sp=>`<span class="chip">${sp}</span>`).join(' ')}</td>
      <td class="text-xs">${s.classes.join(', ')}</td>
      <td class="text-xs">${s.qual}</td>
      <td class="text-xs">${s.join}</td>
      <td><span class="badge ${s.status==='Active'?'badge-green':'badge-amber'}">${s.status}</span></td>
    </tr>`).join('');
}

// ── INQUIRY MODAL ──────────────────────────────────────────
function openInquiryModal() { document.getElementById('modal-overlay').style.display = 'flex'; }
function closeModal()       { document.getElementById('modal-overlay').style.display = 'none'; }
function submitInquiry() {
  const child      = document.getElementById('inq-child').value.trim();
  const parent     = document.getElementById('inq-parent').value.trim();
  const contact    = document.getElementById('inq-contact').value.trim();
  const age        = document.getElementById('inq-age').value.trim();
  const disability = document.getElementById('inq-disability').value;
  const notes      = document.getElementById('inq-notes').value.trim();
  // Validation
  if (!child)   { highlightError('inq-child', 'Child name is required'); return; }
  if (!parent)  { highlightError('inq-parent', 'Parent name is required'); return; }
  if (!contact) { highlightError('inq-contact', 'Contact number is required'); return; }
  clearErrors();
  const newId = 'INQ-' + String(inquiries.length + 1).padStart(3,'0');
  inquiries.unshift({ id:newId, childName:child, parentName:parent, contact, age:parseInt(age)||'—', disability, notes, stage:'new', date:'Apr 20, 2025' });
  closeModal();
  updateInquiryBadge();
  if (currentPage === 'inquiries') renderInquiries();
  if (currentPage === 'dashboard') renderDashboard();
  showToast(`Inquiry for ${child} added to pipeline.`, 'success');
  ['inq-child','inq-parent','inq-contact','inq-age','inq-notes'].forEach(id => document.getElementById(id).value = '');
}
function highlightError(id, msg) {
  const el = document.getElementById(id);
  el.style.borderColor = 'var(--danger)';
  el.placeholder = msg;
  el.focus();
  setTimeout(() => { el.style.borderColor = ''; el.placeholder = ''; }, 3000);
}
function clearErrors() {
  ['inq-child','inq-parent','inq-contact'].forEach(id => {
    document.getElementById(id).style.borderColor = '';
  });
}

// ── PRINT FUNCTIONS ────────────────────────────────────────
function printProfile(studentId) {
  const id = studentId || activeProfileId;
  if (!id) return;
  const s = STUDENTS.find(st => st.id === id);
  const docRows = s.docs.map(d => {
    const color = d.status==='verified'?'#2D8A58':d.status==='uploaded'?'#2E7D9F':d.status==='missing'?'#D95C5C':'#B36B18';
    const label = {verified:'✓ Verified', pending:'⏳ Pending', missing:'✗ Missing', uploaded:'📤 Uploaded'}[d.status];
    return `<tr><td>${d.name}</td><td>${d.type}</td><td>${d.board}</td><td style="color:${color};font-weight:600">${label}</td><td>${d.date}</td></tr>`;
  }).join('');
  const notesHtml = s.notes.map(n => `<div style="border-left:3px solid #2E7D9F;padding:8px 12px;margin-bottom:8px;background:#f9f9f9;border-radius:0 4px 4px 0"><strong>${n.by}</strong> (${n.role}) — ${n.date}<br><em>${n.type}</em>: ${n.text}</div>`).join('');
  const win = window.open('','_blank','width=800,height=700');
  win.document.write(`<!DOCTYPE html><html><head><title>Child Profile — ${s.name}</title>
    <style>body{font-family:Arial,sans-serif;padding:24px;color:#222}h2{color:#1C2B3A;margin-bottom:4px}h3{color:#2E7D9F;margin:18px 0 8px;border-bottom:2px solid #2E7D9F;padding-bottom:4px}.grid{display:grid;grid-template-columns:1fr 1fr;gap:8px;margin-bottom:12px}.box{background:#f5f5f5;border-radius:4px;padding:10px}.label{font-size:10px;text-transform:uppercase;color:#888;font-weight:bold;margin-bottom:3px}.value{font-size:13px;font-weight:600}table{border-collapse:collapse;width:100%;font-size:12px}th,td{border:1px solid #ddd;padding:7px 10px;text-align:left}th{background:#1C2B3A;color:#fff}.badge{display:inline-block;padding:2px 8px;border-radius:12px;font-size:11px;font-weight:bold}@media print{button{display:none}}</style>
    </head><body>
    <h2>CASE — Centre for Autism & Special Education</h2>
    <p style="color:#666;font-size:12px">Child Profile · Generated: Apr 20, 2025 · Internal Use Only</p>
    <h3>Basic Information</h3>
    <div class="grid">
      <div class="box"><div class="label">Student Name</div><div class="value">${s.name}</div></div>
      <div class="box"><div class="label">Student ID</div><div class="value">${s.id}</div></div>
      <div class="box"><div class="label">Date of Birth</div><div class="value">${s.dob} (Age ${s.age})</div></div>
      <div class="box"><div class="label">Enrolled</div><div class="value">${s.enrolledDate}</div></div>
      <div class="box"><div class="label">Classroom</div><div class="value">${s.room}</div></div>
      <div class="box"><div class="label">Class Educator</div><div class="value">${s.educator}</div></div>
    </div>
    <h3>Disability & Certification</h3>
    <div class="grid">
      <div class="box"><div class="label">Primary Disability</div><div class="value">${s.disability}</div></div>
      <div class="box"><div class="label">Board Track</div><div class="value">${s.boardTrack} — ${s.classLevel}</div></div>
      <div class="box"><div class="label">Certification Date</div><div class="value">${s.certDate}</div></div>
      <div class="box"><div class="label">Certifying Body</div><div class="value">${s.certBoard}</div></div>
      <div class="box"><div class="label">Board Concession</div><div class="value">${s.concession}</div></div>
      <div class="box"><div class="label">Concession Status</div><div class="value" style="color:#2D8A58">${s.concessionStatus}</div></div>
    </div>
    <h3>Parent / Contact</h3>
    <div class="grid">
      <div class="box"><div class="label">Parent / Guardian</div><div class="value">${s.parent}</div></div>
      <div class="box"><div class="label">Contact</div><div class="value">${s.contact}</div></div>
      <div class="box"><div class="label">Fee Status</div><div class="value" style="color:${s.feeStatus==='Paid'?'#2D8A58':s.feeStatus==='Overdue'?'#D95C5C':'#B36B18'}">${s.feeStatus}${s.feeBalance>0?' — ₹'+s.feeBalance.toLocaleString()+' due':''}</div></div>
      <div class="box"><div class="label">Donation Funded</div><div class="value">${s.donationFunded?'Yes':'No'}</div></div>
    </div>
    <h3>Documents (${s.docs.length} total)</h3>
    <table><thead><tr><th>Document</th><th>Type</th><th>Required For</th><th>Status</th><th>Date</th></tr></thead>
    <tbody>${docRows}</tbody></table>
    <h3>Staff Notes</h3>
    ${notesHtml || '<p style="color:#888">No notes recorded.</p>'}
    <br><button onclick="window.print()" style="padding:8px 20px;background:#1C2B3A;color:#fff;border:none;border-radius:6px;cursor:pointer;font-size:14px">🖨 Print Profile</button>
    </body></html>`);
  win.document.close();
}

function printFeeReceipt(studentId) {
  const s = STUDENTS.find(st => st.id === studentId);
  const win = window.open('','_blank','width=600,height=500');
  win.document.write(`<!DOCTYPE html><html><head><title>Fee Receipt — ${s.name}</title>
    <style>body{font-family:Arial,sans-serif;padding:32px;max-width:520px;margin:0 auto}.header{text-align:center;border-bottom:3px solid #1C2B3A;padding-bottom:16px;margin-bottom:20px}h2{color:#1C2B3A;margin-bottom:4px}.row{display:flex;justify-content:space-between;padding:8px 0;border-bottom:1px solid #eee;font-size:13px}.label{color:#666}.value{font-weight:600}.total{background:#f0f7ff;padding:12px 0;margin-top:8px;border-radius:4px}.stamp{border:3px solid #2D8A58;color:#2D8A58;font-size:28px;font-weight:900;text-align:center;padding:8px 20px;display:inline-block;border-radius:8px;transform:rotate(-5deg);margin-top:16px}@media print{button{display:none}}</style>
    </head><body>
    <div class="header"><h2>CASE — Centre for Autism & Special Education</h2><p style="color:#666;font-size:12px">Affiliated to SRCC Children's Hospital · Fee Receipt</p></div>
    <div class="row"><span class="label">Receipt No.</span><span class="value">CASE/FEE/${s.id}/${new Date().getFullYear()}</span></div>
    <div class="row"><span class="label">Student Name</span><span class="value">${s.name}</span></div>
    <div class="row"><span class="label">Student ID</span><span class="value">${s.id}</span></div>
    <div class="row"><span class="label">Classroom</span><span class="value">${s.room}</span></div>
    <div class="row"><span class="label">Parent / Guardian</span><span class="value">${s.parent}</span></div>
    <div class="row"><span class="label">Term Fee</span><span class="value">₹${s.termFee.toLocaleString()}</span></div>
    <div class="row"><span class="label">Concession Applied</span><span class="value">${s.concession}</span></div>
    <div class="row"><span class="label">Amount Paid</span><span class="value" style="color:#2D8A58">₹${s.feePaid.toLocaleString()}</span></div>
    <div class="row total"><span class="label" style="font-weight:bold">Balance Due</span><span class="value" style="color:${s.feeBalance>0?'#D95C5C':'#2D8A58'};font-size:16px">${s.feeBalance>0?'₹'+s.feeBalance.toLocaleString():'NIL'}</span></div>
    <div class="row"><span class="label">Date</span><span class="value">Apr 20, 2025</span></div>
    ${s.feeStatus==='Paid'?'<div style="text-align:center;margin-top:16px"><div class="stamp">PAID IN FULL</div></div>':''}
    <p style="font-size:10px;color:#aaa;margin-top:20px;text-align:center">This is a computer-generated receipt. For queries contact admin@case.edu.in</p>
    <br><button onclick="window.print()" style="display:block;width:100%;padding:10px;background:#1C2B3A;color:#fff;border:none;border-radius:6px;cursor:pointer;font-size:14px">🖨 Print Receipt</button>
    </body></html>`);
  win.document.close();
}

function printDocChecklist(studentId) {
  const id = studentId || activeProfileId;
  const s  = STUDENTS.find(st => st.id === id);
  const rows = s.docs.map(d => {
    const color = {verified:'#2D8A58',uploaded:'#2E7D9F',pending:'#B36B18',missing:'#D95C5C'}[d.status];
    const label = {verified:'✓ Verified', uploaded:'📤 Uploaded', pending:'⏳ Pending', missing:'✗ Missing'}[d.status];
    const cb    = (d.status==='verified'||d.status==='uploaded') ? '☑' : '☐';
    return `<tr><td style="font-size:16px;text-align:center">${cb}</td><td>${d.name}</td><td>${d.type}</td><td>${d.board}</td><td style="color:${color};font-weight:600">${label}</td><td>${d.date}</td></tr>`;
  }).join('');
  const win = window.open('','_blank','width=700,height=500');
  win.document.write(`<!DOCTYPE html><html><head><title>Document Checklist — ${s.name}</title>
    <style>body{font-family:Arial,sans-serif;padding:24px}h2{color:#1C2B3A}h3{color:#2E7D9F}table{border-collapse:collapse;width:100%;font-size:12px}th,td{border:1px solid #ddd;padding:8px 10px}th{background:#1C2B3A;color:#fff}p{color:#666;font-size:12px}@media print{button{display:none}}</style>
    </head><body>
    <h2>CASE — Document Checklist</h2>
    <h3>${s.name} (${s.id}) — ${s.boardTrack} — ${s.classLevel}</h3>
    <p>Generated: Apr 20, 2025 · Parent: ${s.parent} · Contact: ${s.contact}</p>
    <table><thead><tr><th>✓</th><th>Document</th><th>Type</th><th>Required For</th><th>Status</th><th>Date</th></tr></thead>
    <tbody>${rows}</tbody></table>
    <p style="margin-top:12px">Missing: ${s.docs.filter(d=>d.status==='missing').length} · Pending: ${s.docs.filter(d=>d.status==='pending').length} · Verified: ${s.docs.filter(d=>d.status==='verified'||d.status==='uploaded').length}</p>
    <br><button onclick="window.print()" style="padding:8px 20px;background:#1C2B3A;color:#fff;border:none;border-radius:6px;cursor:pointer;font-size:14px">🖨 Print Checklist</button>
    </body></html>`);
  win.document.close();
}

// ── TOAST ──────────────────────────────────────────────────
function showToast(msg, type) {
  let t = document.getElementById('toast');
  if (!t) { t = document.createElement('div'); t.id = 'toast'; document.body.appendChild(t); }
  const bg = type === 'success' ? '#1a3a2a' : type === 'error' ? '#3a1a1a' : '#1a2a3a';
  t.style.cssText = `position:fixed;bottom:52px;right:20px;background:${bg};color:#fff;padding:11px 18px;border-radius:8px;font-size:13px;font-weight:500;z-index:9999;box-shadow:0 4px 20px rgba(0,0,0,0.25);opacity:1;transition:opacity 0.4s;max-width:360px;line-height:1.4`;
  t.textContent = msg;
  clearTimeout(t._timeout);
  t._timeout = setTimeout(() => { t.style.opacity = '0'; }, 3500);
}

// ── INIT ───────────────────────────────────────────────────
document.addEventListener('DOMContentLoaded', () => {
  nav('dashboard');
  updateInquiryBadge();
  // Populate notes student select
  const sel = document.getElementById('add-note-student');
  if (sel) STUDENTS.forEach(s => { const o = document.createElement('option'); o.value = s.id; o.textContent = s.name; sel.appendChild(o); });
});
