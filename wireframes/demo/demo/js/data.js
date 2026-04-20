/* =========================================================
   CASE DEMO DATA — mirrors case_data.csv + extended fields
   ========================================================= */

const STUDENTS = [
  { id:'CASE-001', name:'Arjun Sharma', avatar:'AS', color:'#2E7D9F',
    dob:'12 Mar 2012', age:13, room:'Rainbow Room', educator:'Ms. Priya Kulkarni',
    disability:'Autism Spectrum Disorder (ASD)', boardTrack:'SSE Board', classLevel:'Level II',
    certDate:'Jan 2024', certBoard:'RCI', concession:'Extra time (30 min)',
    concessionReason:'RCI Certified Disability', concessionStatus:'Approved',
    enrolledDate:'Apr 2024', status:'Active',
    parent:'Mr. Ramesh Sharma', contact:'98765 43210',
    termFee:25000, feePaid:25000, feeBalance:0, feeStatus:'Paid',
    donationFunded: false,
    notes:[
      {by:'Ms. Priya Kulkarni', role:'Special Educator', date:'15 Apr 2025', type:'Progress', text:'Arjun has shown consistent improvement in literacy. Able to read simple sentences with minimal prompting. Social interaction during group activities still needs support.', tag:'badge-blue'},
      {by:'Ms. Kavita Shah', role:'Speech Therapist', date:'10 Apr 2025', type:'Concern', text:'Articulation of multi-syllable words improving. Recommend 2 sessions/week continuation.', tag:'badge-amber'},
      {by:'Ms. Anita Naik', role:'Occupational Therapist', date:'02 Apr 2025', type:'Progress', text:'Fine motor coordination improving. Pencil grip is more stable compared to last term.', tag:'badge-green'}
    ],
    docs:[
      {name:'Disability Certificate', type:'Certification', board:'SSE / NIOS', status:'verified', date:'Jan 2024', file:'disability_cert_CASE001.pdf'},
      {name:'RCI Registration', type:'Certification', board:'SSE / NIOS', status:'verified', date:'Jan 2024', file:'rci_CASE001.pdf'},
      {name:'School Transfer Certificate', type:'Academic', board:'SSE', status:'verified', date:'Feb 2024', file:'stc_CASE001.pdf'},
      {name:'Aadhaar Card', type:'ID Proof', board:'Both', status:'verified', date:'Mar 2024', file:'aadhaar_CASE001.pdf'},
      {name:'Passport Size Photo (4 copies)', type:'Photo', board:'SSE', status:'verified', date:'Mar 2024', file:'photo_CASE001.pdf'},
      {name:'SSE Registration Form', type:'Board Form', board:'SSE', status:'pending', date:'-', file:''},
      {name:'Previous Report Cards (2 years)', type:'Academic', board:'SSE', status:'verified', date:'Apr 2024', file:'reports_CASE001.pdf'}
    ]
  },
  { id:'CASE-002', name:'Riya Patel', avatar:'RP', color:'#E8913A',
    dob:'05 Jul 2013', age:11, room:'Rainbow Room', educator:'Ms. Priya Kulkarni',
    disability:'Intellectual Disability (Mild)', boardTrack:'NIOS Board', classLevel:'Level I',
    certDate:'Mar 2023', certBoard:'RCI / NIMH', concession:'Scribe + Extra time',
    concessionReason:'RCI Certified Disability', concessionStatus:'Approved',
    enrolledDate:'Jun 2024', status:'Active',
    parent:'Mrs. Sunita Patel', contact:'91234 56789',
    termFee:25000, feePaid:15000, feeBalance:10000, feeStatus:'Partial',
    donationFunded: false,
    notes:[
      {by:'Ms. Priya Kulkarni', role:'Special Educator', date:'14 Apr 2025', type:'Progress', text:'Riya is responding well to picture-based instructions. Math concepts up to addition/subtraction mastered.', tag:'badge-green'},
      {by:'Ms. Kavita Shah', role:'Speech Therapist', date:'08 Apr 2025', type:'Progress', text:'Vocabulary building progressing. Can form 5-6 word sentences now. Expressive language improving.', tag:'badge-green'}
    ],
    docs:[
      {name:'Disability Certificate', type:'Certification', board:'SSE / NIOS', status:'verified', date:'Mar 2023', file:'disability_cert_CASE002.pdf'},
      {name:'NIMH Assessment Report', type:'Assessment', board:'NIOS', status:'verified', date:'Mar 2023', file:'nimh_CASE002.pdf'},
      {name:'Aadhaar Card', type:'ID Proof', board:'Both', status:'verified', date:'Jun 2024', file:'aadhaar_CASE002.pdf'},
      {name:'NIOS Registration Form', type:'Board Form', board:'NIOS', status:'missing', date:'-', file:''},
      {name:'School Transfer Certificate', type:'Academic', board:'NIOS', status:'pending', date:'-', file:''},
      {name:'Passport Size Photo', type:'Photo', board:'NIOS', status:'verified', date:'Jun 2024', file:'photo_CASE002.pdf'}
    ]
  },
  { id:'CASE-003', name:'Kabir Mehta', avatar:'KM', color:'#4CAF7D',
    dob:'22 Nov 2011', age:13, room:'Sunshine Room', educator:'Ms. Sangeeta Mane',
    disability:'Down Syndrome', boardTrack:'SSE Board', classLevel:'Level II',
    certDate:'Jun 2022', certBoard:'RCI', concession:'Extra time (30 min)',
    concessionReason:'RCI Certified Disability', concessionStatus:'Approved',
    enrolledDate:'Jan 2025', status:'Active',
    parent:'Mr. Vikram Mehta', contact:'99887 76655',
    termFee:22000, feePaid:22000, feeBalance:0, feeStatus:'Paid',
    donationFunded: false,
    notes:[
      {by:'Ms. Sangeeta Mane', role:'Special Educator', date:'16 Apr 2025', type:'Progress', text:'Kabir completed Chapter 3 of functional math workbook. Counting up to 50 now accurate.', tag:'badge-green'}
    ],
    docs:[
      {name:'Disability Certificate', type:'Certification', board:'SSE / NIOS', status:'verified', date:'Jun 2022', file:'disability_cert_CASE003.pdf'},
      {name:'Aadhaar Card', type:'ID Proof', board:'Both', status:'verified', date:'Jan 2025', file:'aadhaar_CASE003.pdf'},
      {name:'School Transfer Certificate', type:'Academic', board:'SSE', status:'verified', date:'Jan 2025', file:'stc_CASE003.pdf'},
      {name:'SSE Registration Form', type:'Board Form', board:'SSE', status:'uploaded', date:'Mar 2025', file:'sse_form_CASE003.pdf'},
      {name:'Passport Size Photo', type:'Photo', board:'SSE', status:'verified', date:'Jan 2025', file:'photo_CASE003.pdf'}
    ]
  },
  { id:'CASE-004', name:'Sneha Joshi', avatar:'SJ', color:'#9B59B6',
    dob:'18 Feb 2012', age:12, room:'Sunshine Room', educator:'Ms. Sangeeta Mane',
    disability:'Autism Spectrum Disorder (ASD)', boardTrack:'SSE Board', classLevel:'Level I',
    certDate:'Dec 2023', certBoard:'RCI', concession:'Writer Facility',
    concessionReason:'Economic Background — Concession Applied', concessionStatus:'Approved',
    enrolledDate:'Sep 2024', status:'Active',
    parent:'Mrs. Kavita Joshi', contact:'90123 45678',
    termFee:22000, feePaid:11000, feeBalance:11000, feeStatus:'Partial',
    donationFunded: true,
    notes:[
      {by:'Ms. Sangeeta Mane', role:'Special Educator', date:'15 Apr 2025', type:'Concern', text:'Sneha is having difficulty with reading comprehension in Hindi. Suggest extra practice worksheets.', tag:'badge-amber'},
      {by:'Ms. Anita Naik', role:'Occupational Therapist', date:'09 Apr 2025', type:'Progress', text:'Writing posture and grip improving. Can now write for 20 mins without fatigue.', tag:'badge-green'}
    ],
    docs:[
      {name:'Disability Certificate', type:'Certification', board:'SSE / NIOS', status:'verified', date:'Dec 2023', file:'disability_cert_CASE004.pdf'},
      {name:'Income Certificate (Concession)', type:'Financial', board:'Internal', status:'verified', date:'Sep 2024', file:'income_cert_CASE004.pdf'},
      {name:'Aadhaar Card', type:'ID Proof', board:'Both', status:'verified', date:'Sep 2024', file:'aadhaar_CASE004.pdf'},
      {name:'School Transfer Certificate', type:'Academic', board:'SSE', status:'pending', date:'-', file:''},
      {name:'SSE Registration Form', type:'Board Form', board:'SSE', status:'missing', date:'-', file:''}
    ]
  },
  { id:'CASE-005', name:'Dev Kulkarni', avatar:'DK', color:'#16A085',
    dob:'30 Aug 2010', age:15, room:'Ocean Room', educator:'Mr. Rohan Desai',
    disability:'ADHD + Learning Disability', boardTrack:'NIOS Board', classLevel:'Level III',
    certDate:'Aug 2021', certBoard:'RCI', concession:'Extra time (1 hour)',
    concessionReason:'RCI Certified Disability', concessionStatus:'Approved',
    enrolledDate:'Mar 2024', status:'Active',
    parent:'Mr. Sunil Kulkarni', contact:'97654 32109',
    termFee:20000, feePaid:0, feeBalance:20000, feeStatus:'Overdue',
    donationFunded: false,
    notes:[
      {by:'Mr. Rohan Desai', role:'Special Educator', date:'16 Apr 2025', type:'Concern', text:'Dev missed 3 consecutive classes this week. Parent contact needed. Performance in science worksheets declining.', tag:'badge-red'},
      {by:'Ms. Kavita Shah', role:'Speech Therapist', date:'05 Apr 2025', type:'Progress', text:'Reading fluency improved significantly. Science chapter reading done independently.', tag:'badge-green'}
    ],
    docs:[
      {name:'Disability Certificate', type:'Certification', board:'SSE / NIOS', status:'verified', date:'Aug 2021', file:'disability_cert_CASE005.pdf'},
      {name:'Aadhaar Card', type:'ID Proof', board:'Both', status:'verified', date:'Mar 2024', file:'aadhaar_CASE005.pdf'},
      {name:'NIOS Registration Form', type:'Board Form', board:'NIOS', status:'uploaded', date:'Feb 2025', file:'nios_form_CASE005.pdf'},
      {name:'Previous Report Cards', type:'Academic', board:'NIOS', status:'verified', date:'Mar 2024', file:'reports_CASE005.pdf'}
    ]
  },
  { id:'CASE-006', name:'Naina Bhatt', avatar:'NB', color:'#D95C5C',
    dob:'14 May 2013', age:11, room:'Ocean Room', educator:'Mr. Rohan Desai',
    disability:'Learning Disability (Dyslexia)', boardTrack:'SSE Board', classLevel:'Level I',
    certDate:'Feb 2024', certBoard:'RCI', concession:'Reader + Extra time',
    concessionReason:'RCI Certified Disability', concessionStatus:'Approved',
    enrolledDate:'Jul 2024', status:'Active',
    parent:'Mrs. Deepa Bhatt', contact:'96543 21098',
    termFee:22000, feePaid:22000, feeBalance:0, feeStatus:'Paid',
    donationFunded: false,
    notes:[
      {by:'Mr. Rohan Desai', role:'Special Educator', date:'14 Apr 2025', type:'Progress', text:'Naina is progressing well with phonics. Reading 3-letter words without reader support now.', tag:'badge-green'}
    ],
    docs:[
      {name:'Disability Certificate', type:'Certification', board:'SSE / NIOS', status:'verified', date:'Feb 2024', file:'disability_cert_CASE006.pdf'},
      {name:'Aadhaar Card', type:'ID Proof', board:'Both', status:'verified', date:'Jul 2024', file:'aadhaar_CASE006.pdf'},
      {name:'SSE Registration Form', type:'Board Form', board:'SSE', status:'pending', date:'-', file:''},
      {name:'School Transfer Certificate', type:'Academic', board:'SSE', status:'verified', date:'Jul 2024', file:'stc_CASE006.pdf'},
      {name:'Passport Size Photo', type:'Photo', board:'SSE', status:'verified', date:'Jul 2024', file:'photo_CASE006.pdf'}
    ]
  },
  { id:'CASE-007', name:'Meera Gupta', avatar:'MG', color:'#4CAF7D',
    dob:'03 Jan 2012', age:13, room:'Rainbow Room', educator:'Ms. Priya Kulkarni',
    disability:'Intellectual Disability (Moderate)', boardTrack:'NIOS Board', classLevel:'Level II',
    certDate:'Sep 2022', certBoard:'RCI', concession:'Scribe + Extra time',
    concessionReason:'Economic Background — Donation Funded', concessionStatus:'Approved',
    enrolledDate:'Aug 2024', status:'Active',
    parent:'Mr. Anil Gupta', contact:'95432 10987',
    termFee:25000, feePaid:25000, feeBalance:0, feeStatus:'Paid',
    donationFunded: true,
    notes:[
      {by:'Ms. Priya Kulkarni', role:'Special Educator', date:'15 Apr 2025', type:'Progress', text:'Meera completed Social Studies Chapter 4. Memory recall for key facts improving steadily.', tag:'badge-blue'}
    ],
    docs:[
      {name:'Disability Certificate', type:'Certification', board:'SSE / NIOS', status:'verified', date:'Sep 2022', file:'disability_cert_CASE007.pdf'},
      {name:'Aadhaar Card', type:'ID Proof', board:'Both', status:'verified', date:'Aug 2024', file:'aadhaar_CASE007.pdf'},
      {name:'NIOS Registration Form', type:'Board Form', board:'NIOS', status:'missing', date:'-', file:''},
      {name:'Income Certificate (Concession)', type:'Financial', board:'Internal', status:'verified', date:'Aug 2024', file:'income_cert_CASE007.pdf'}
    ]
  },
  { id:'CASE-008', name:'Raj Thakur', avatar:'RT', color:'#2E7D9F',
    dob:'25 Oct 2011', age:14, room:'Sunshine Room', educator:'Ms. Sangeeta Mane',
    disability:'Autism Spectrum Disorder (ASD)', boardTrack:'SSE Board', classLevel:'Level II',
    certDate:'Apr 2023', certBoard:'RCI', concession:'Extra time (30 min)',
    concessionReason:'RCI Certified Disability', concessionStatus:'Approved',
    enrolledDate:'Jun 2025', status:'Active',
    parent:'Mr. Dinesh Thakur', contact:'94321 09876',
    termFee:22000, feePaid:10000, feeBalance:12000, feeStatus:'Partial',
    donationFunded: false,
    notes:[
      {by:'Ms. Sangeeta Mane', role:'Special Educator', date:'16 Apr 2025', type:'Observation', text:'Raj is a new admission. Initial assessment done. Baseline for English literacy established. Recommend science worksheet adaptation.', tag:'badge-blue'}
    ],
    docs:[
      {name:'Disability Certificate', type:'Certification', board:'SSE / NIOS', status:'verified', date:'Apr 2023', file:'disability_cert_CASE008.pdf'},
      {name:'Aadhaar Card', type:'ID Proof', board:'Both', status:'pending', date:'-', file:''},
      {name:'School Transfer Certificate', type:'Academic', board:'SSE', status:'uploaded', date:'Jun 2025', file:'stc_CASE008.pdf'},
      {name:'SSE Registration Form', type:'Board Form', board:'SSE', status:'missing', date:'-', file:''}
    ]
  },
  { id:'CASE-009', name:'Pooja Sinha', avatar:'PS', color:'#E8913A',
    dob:'07 Jun 2014', age:10, room:'Ocean Room', educator:'Mr. Rohan Desai',
    disability:'Down Syndrome', boardTrack:'NIOS Board', classLevel:'Level I',
    certDate:'Jul 2024', certBoard:'RCI', concession:'Scribe + Extra time',
    concessionReason:'Economic Background — Donation Funded', concessionStatus:'Approved',
    enrolledDate:'Nov 2024', status:'Active',
    parent:'Mrs. Asha Sinha', contact:'93210 98765',
    termFee:20000, feePaid:20000, feeBalance:0, feeStatus:'Paid',
    donationFunded: true,
    notes:[
      {by:'Mr. Rohan Desai', role:'Special Educator', date:'13 Apr 2025', type:'Progress', text:'Pooja is adapting well to the class routine. Number recognition up to 20 achieved. Happy and engaged student.', tag:'badge-green'}
    ],
    docs:[
      {name:'Disability Certificate', type:'Certification', board:'SSE / NIOS', status:'verified', date:'Jul 2024', file:'disability_cert_CASE009.pdf'},
      {name:'Aadhaar Card', type:'ID Proof', board:'Both', status:'verified', date:'Nov 2024', file:'aadhaar_CASE009.pdf'},
      {name:'NIOS Registration Form', type:'Board Form', board:'NIOS', status:'missing', date:'-', file:''},
      {name:'Income Certificate (Concession)', type:'Financial', board:'Internal', status:'verified', date:'Nov 2024', file:'income_cert_CASE009.pdf'}
    ]
  },
  { id:'CASE-010', name:'Aarav Verma', avatar:'AV', color:'#9B59B6',
    dob:'19 Sep 2012', age:12, room:'Rainbow Room', educator:'Ms. Priya Kulkarni',
    disability:'ADHD', boardTrack:'SSE Board', classLevel:'Level I',
    certDate:'Nov 2023', certBoard:'RCI', concession:'Extra time (30 min)',
    concessionReason:'RCI Certified Disability', concessionStatus:'Approved',
    enrolledDate:'Feb 2025', status:'Active',
    parent:'Mr. Prashant Verma', contact:'92109 87654',
    termFee:25000, feePaid:25000, feeBalance:0, feeStatus:'Paid',
    donationFunded: false,
    notes:[
      {by:'Ms. Priya Kulkarni', role:'Special Educator', date:'16 Apr 2025', type:'Progress', text:'Aarav is responding well to structured classroom time. Attention span improved from 10 mins to 25 mins in focused tasks.', tag:'badge-green'}
    ],
    docs:[
      {name:'Disability Certificate', type:'Certification', board:'SSE / NIOS', status:'verified', date:'Nov 2023', file:'disability_cert_CASE010.pdf'},
      {name:'Aadhaar Card', type:'ID Proof', board:'Both', status:'verified', date:'Feb 2025', file:'aadhaar_CASE010.pdf'},
      {name:'School Transfer Certificate', type:'Academic', board:'SSE', status:'verified', date:'Feb 2025', file:'stc_CASE010.pdf'},
      {name:'SSE Registration Form', type:'Board Form', board:'SSE', status:'uploaded', date:'Apr 2025', file:'sse_form_CASE010.pdf'},
      {name:'Passport Size Photo', type:'Photo', board:'SSE', status:'verified', date:'Feb 2025', file:'photo_CASE010.pdf'}
    ]
  }
];

const STAFF = [
  { id:'EMP-001', name:'Ms. Priya Kulkarni', avatar:'PK', color:'#2E7D9F', designation:'Senior Special Educator', dept:'Special Education', specs:['ASD','Behavior Management'], classes:['Rainbow Room'], qual:'B.Ed (Special Ed), RCI Certified', join:'Mar 2021', status:'Active', salary:'₹42,000' },
  { id:'EMP-002', name:'Ms. Sangeeta Mane', avatar:'SM', color:'#E8913A', designation:'Special Educator', dept:'Special Education', specs:['Intellectual Disability','Down Syndrome'], classes:['Sunshine Room'], qual:'M.Sc. Psychology, RCI Registered', join:'Jun 2022', status:'Active', salary:'₹35,000' },
  { id:'EMP-003', name:'Mr. Rohan Desai', avatar:'RD', color:'#4CAF7D', designation:'Special Educator', dept:'Special Education', specs:['ADHD','Learning Disability'], classes:['Ocean Room'], qual:'B.Ed (Sp. Ed), NIMH Diploma', join:'Jan 2023', status:'Active', salary:'₹30,000' },
  { id:'EMP-004', name:'Ms. Anita Naik', avatar:'AN', color:'#9B59B6', designation:'Occupational Therapist', dept:'Therapy', specs:['Sensory Processing','Fine Motor'], classes:['All Rooms (Support)'], qual:'B.OT, AIOTA Member', join:'Aug 2022', status:'Active', salary:'₹45,000' },
  { id:'EMP-005', name:'Ms. Kavita Shah', avatar:'KS', color:'#D95C5C', designation:'Speech & Language Pathologist', dept:'Therapy', specs:['AAC','Language Development'], classes:['All Rooms (Support)'], qual:'M.Sc. Audiology & SLP', join:'Nov 2021', status:'On Leave', salary:'₹48,000' },
  { id:'EMP-006', name:'Ms. Prerna Singh', avatar:'PS', color:'#16A085', designation:'Admin Coordinator', dept:'Administration', specs:['Front Desk','Records'], classes:['-'], qual:'B.Com, MS Office', join:'Feb 2022', status:'Active', salary:'₹22,000' }
];

const CLASSES = [
  { id:'C-01', name:'Rainbow Room', icon:'🌈', colorClass:'tt-blue', level:'SSE Primary', track:'SSE Board', capacity:5, studentIds:['CASE-001','CASE-002','CASE-007','CASE-010'], educator:'Ms. Priya Kulkarni', educatorId:'EMP-001', timing:'9:00 AM – 2:00 PM', desc:'SSE Board preparation group. Focus on functional literacy, numeracy, and social skills aligned to SSE syllabus.' },
  { id:'C-02', name:'Sunshine Room', icon:'☀️', colorClass:'tt-amber', level:'SSE Secondary', track:'SSE Board', capacity:5, studentIds:['CASE-003','CASE-004','CASE-008'], educator:'Ms. Sangeeta Mane', educatorId:'EMP-002', timing:'9:00 AM – 2:00 PM', desc:'SSE Board secondary level group. Covers modified SSE syllabus with additional life skills component.' },
  { id:'C-03', name:'Ocean Room', icon:'🌊', colorClass:'tt-green', level:'NIOS Group', track:'NIOS Board', capacity:5, studentIds:['CASE-005','CASE-006','CASE-009'], educator:'Mr. Rohan Desai', educatorId:'EMP-003', timing:'9:00 AM – 2:00 PM', desc:'NIOS Board track. Flexible curriculum suited for students with varied learning needs targeting NIOS open schooling exams.' }
];

const INQUIRIES = [
  { id:'INQ-001', childName:'Ayaan Khan', parentName:'Mr. Salim Khan', contact:'98112 33456', age:11, disability:'Suspected ASD', notes:'Walk-in today. Parent mentioned speech delay and social withdrawal.', stage:'new', date:'20 Apr 2025', followUpDate:'23 Apr 2025' },
  { id:'INQ-002', childName:'Priya Deshmukh', parentName:'Mrs. Leena Deshmukh', contact:'97223 44567', age:9, disability:'Down Syndrome', notes:'Referred by SRCC. Documents partially ready.', stage:'new', date:'18 Apr 2025', followUpDate:'24 Apr 2025' },
  { id:'INQ-003', childName:'Rohan Patil', parentName:'Mr. Ganesh Patil', contact:'96334 55678', age:13, disability:'Learning Disability', notes:'Assessment scheduled for Apr 24th with Ms. Priya K.', stage:'assessment', date:'15 Apr 2025', assessmentDate:'24 Apr 2025' },
  { id:'INQ-004', childName:'Simran Kaur', parentName:'Mr. Gurjeet Kaur', contact:'95445 66789', age:12, disability:'Intellectual Disability (Mild)', notes:'Assessment done. Under review — fits SSE Level I profile.', stage:'review', date:'10 Apr 2025', assessmentDate:'16 Apr 2025' },
  { id:'INQ-005', childName:'Harsh Sharma', parentName:'Mrs. Rekha Sharma', contact:'94556 77890', age:14, disability:'Cerebral Palsy', notes:'Assessment completed. Does not fit current class grouping — mobility support beyond current capacity. Referred to appropriate facility.', stage:'rejected', date:'05 Apr 2025' },
  { id:'INQ-006', childName:'Tanvi Mehta', parentName:'Mr. Kiran Mehta', contact:'93667 88901', age:10, disability:'ASD + Mild ID', notes:'Admitted to Rainbow Room. Enrolled as CASE-011.', stage:'admitted', date:'01 Apr 2025' }
];

// Per-class timetable
const TIMETABLE = {
  'Rainbow Room': {
    '9:00–10:00':  {Mon:'Language & Literacy',Tue:'Mathematics',Wed:'Language & Literacy',Thu:'Social Studies',Fri:'Mathematics'},
    '10:00–11:00': {Mon:'Social Studies',Tue:'English Reading',Wed:'Mathematics',Thu:'Language & Literacy',Fri:'Science'},
    '11:00–11:15': {Mon:'— Break —',Tue:'— Break —',Wed:'— Break —',Thu:'— Break —',Fri:'— Break —'},
    '11:15–12:15': {Mon:'OT / Sensory (Ms. Anita)',Tue:'Life Skills',Wed:'Speech Therapy (Ms. Kavita)',Thu:'Art & Expression',Fri:'Physical Education'},
    '12:15–1:00':  {Mon:'— Lunch —',Tue:'— Lunch —',Wed:'— Lunch —',Thu:'— Lunch —',Fri:'— Lunch —'},
    '1:00–2:00':   {Mon:'Revision & Practice',Tue:'Worksheet Practice',Wed:'Revision & Practice',Thu:'Assessment / Test',Fri:'Group Activity'}
  },
  'Sunshine Room': {
    '9:00–10:00':  {Mon:'Mathematics',Tue:'Language & Literacy',Wed:'Science',Thu:'Mathematics',Fri:'English Reading'},
    '10:00–11:00': {Mon:'English Reading',Tue:'Social Studies',Wed:'Language & Literacy',Thu:'Life Skills',Fri:'Language & Literacy'},
    '11:00–11:15': {Mon:'— Break —',Tue:'— Break —',Wed:'— Break —',Thu:'— Break —',Fri:'— Break —'},
    '11:15–12:15': {Mon:'Life Skills',Tue:'OT / Sensory (Ms. Anita)',Wed:'Art & Expression',Thu:'Speech Therapy (Ms. Kavita)',Fri:'Physical Education'},
    '12:15–1:00':  {Mon:'— Lunch —',Tue:'— Lunch —',Wed:'— Lunch —',Thu:'— Lunch —',Fri:'— Lunch —'},
    '1:00–2:00':   {Mon:'Worksheet Practice',Tue:'Revision & Practice',Wed:'Assessment / Test',Thu:'Revision & Practice',Fri:'Group Activity'}
  },
  'Ocean Room': {
    '9:00–10:00':  {Mon:'Science',Tue:'Mathematics',Wed:'English Reading',Thu:'Language & Literacy',Fri:'Social Studies'},
    '10:00–11:00': {Mon:'Language & Literacy',Tue:'Science',Wed:'Social Studies',Thu:'Mathematics',Fri:'English Reading'},
    '11:00–11:15': {Mon:'— Break —',Tue:'— Break —',Wed:'— Break —',Thu:'— Break —',Fri:'— Break —'},
    '11:15–12:15': {Mon:'Speech Therapy (Ms. Kavita)',Tue:'Life Skills',Wed:'OT / Sensory (Ms. Anita)',Thu:'Art & Expression',Fri:'Physical Education'},
    '12:15–1:00':  {Mon:'— Lunch —',Tue:'— Lunch —',Wed:'— Lunch —',Thu:'— Lunch —',Fri:'— Lunch —'},
    '1:00–2:00':   {Mon:'Revision & Practice',Tue:'Assessment / Test',Wed:'Worksheet Practice',Thu:'Revision & Practice',Fri:'Group Activity'}
  }
};

// Subject color classes
const SUBJECT_COLORS = {
  'Language & Literacy': 'tt-blue',
  'Mathematics': 'tt-amber',
  'English Reading': 'tt-green',
  'Social Studies': 'tt-purple',
  'Science': 'tt-teal',
  'Life Skills': 'tt-rose',
  'Physical Education': 'tt-green',
  'Art & Expression': 'tt-purple',
  'OT / Sensory (Ms. Anita)': 'tt-rose',
  'Speech Therapy (Ms. Kavita)': 'tt-rose',
  'Revision & Practice': 'tt-blue',
  'Worksheet Practice': 'tt-teal',
  'Assessment / Test': 'tt-amber',
  'Group Activity': 'tt-purple',
  '— Break —': 'tt-empty',
  '— Lunch —': 'tt-empty'
};

const ACTIVITY_FEED = [
  {icon:'📋', iconBg:'#E3F0F7', text:'New inquiry from <strong>Ayaan Khan</strong> — walk-in, suspected ASD', time:'2 hrs ago'},
  {icon:'💳', iconBg:'#E8F7EF', text:'Fee payment of ₹22,000 recorded for <strong>Kabir Mehta</strong>', time:'4 hrs ago'},
  {icon:'📄', iconBg:'#FEF3E2', text:'Document pending: SSE Registration Form for <strong>Riya Patel</strong>', time:'Yesterday'},
  {icon:'📝', iconBg:'#F0EAFF', text:'Note added by <strong>Ms. Priya Kulkarni</strong> for Arjun Sharma', time:'Yesterday'},
  {icon:'🏫', iconBg:'#E3F0F7', text:'<strong>Raj Thakur</strong> assigned to Sunshine Room by Admin', time:'2 days ago'},
  {icon:'⚠️', iconBg:'#FDEAEA', text:'Fee overdue — <strong>Dev Kulkarni</strong> (₹20,000 since Mar 2025)', time:'2 days ago'}
];
