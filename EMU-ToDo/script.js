// Helper function to escape attributes for HTML
function escapeAttr(str) {
    if (typeof str !== 'string') return '';
    return str.replace(/"/g, '"').replace(/'/g, '');
}

// Helper function to show temporary messages on an element
function showTemporaryMessage(element, message, duration = 2000) {
    const originalText = element.textContent;
    const originalTitle = element.title; // Save original title
    element.textContent = message;
    element.title = message; // Optionally update title too
    element.style.pointerEvents = 'none'; // Disable further clicks temporarily

    setTimeout(() => {
        element.textContent = originalText;
        element.title = originalTitle; // Restore original title
        element.style.pointerEvents = 'auto'; // Re-enable clicks
    }, duration);
}


document.addEventListener('DOMContentLoaded', () => {
    // --- CONFIGURATION & STATE ---
    const TASKS_DEFINITION = [
        { id: 'docIntensiv', desc: 'Dokumentation Intensivdiagnostik', path: '\\\\sg.hcare.ch\\store\\KSSG NL\\03_Ärztliche Bereiche_Spezialisierungen\\Epilepsiezentrum\\Visitenbögen\\Intensivdiagnostik\\2025' },
        { id: 'statEpilepsie', desc: 'Statistik Epilepsiezentrum', path: '\\\\sg.hcare.ch\\store\\KSSG NL\\03_Ärztliche Bereiche_Spezialisierungen\\Epilepsiezentrum\\Statistik' },
        { id: 'visitenLT', desc: 'Visitenbögen LT-EEG/Intensivdiagnostik', path: '\\\\sg.hcare.ch\\store\\KSSG NL\\03_Ärztliche Bereiche_Spezialisierungen\\Epilepsiezentrum\\Visitenbögen' },
        { id: 'laufzettelKomplex', desc: 'Laufzettel Komplexbehandlung Epilepsie', path: '\\\\sg.hcare.ch\\store\\KSSG NL\\03_Ärztliche Bereiche_Spezialisierungen\\Komplexbehandlungen\\Epilepsiekomplex' },
        { id: 'eegBefund1', desc: 'EEG Befundung fertig 1. Teil' },
        { id: 'austrittOA', desc: 'Austrittsbericht fertig und zu OA' },
        { id: 'nachbesprAnm', desc: 'Nachbesprechung angemeldet', notePat1: '(Abschliessende LT-EEG Befundbesprechung in ca. 4 Wochen)' },
        { id: 'eegBesprDef', desc: 'EEG besprochen und definitiv befundet' },
        { id: 'ergaenzAustritt', desc: 'Ergänzung zum Austrittsbericht fertig' }
    ];
    const OLD_LOCAL_STORAGE_KEY = 'epilepsieChecklistAllData'; // For migration
    const LOCAL_STORAGE_KEY = 'epilepsieChecklistAppWideData_v1'; // New key for new structure
    
    let appData = {
        weeks: [],
        general: {
            todos: [], // { id: string, text: string, completed: boolean }
            notes: ""
        }
    };
    let currentWeekId = null; // Store the ID of the currently selected week

    // --- DOM ELEMENTS ---
    // General Section
    const generalTodoList = document.getElementById('generalTodoList');
    const addTodoInput = document.getElementById('addTodoInput');
    const addTodoButton = document.getElementById('addTodoButton');
    const generalNotesTextarea = document.getElementById('generalNotesTextarea');

    // Weeks Section
    const overviewContent = document.getElementById('overviewContent');
    const weekSelector = document.getElementById('weekSelector');
    const currentWeekNumberInput = document.getElementById('currentWeekNumberInput');
    const currentWeekContentDiv = document.getElementById('currentWeekContent');
    const currentWeekSection = document.getElementById('currentWeekSection'); // Added for scrolling
    const patient1NameInput = document.getElementById('patient1NameInput');
    const patient2NameInput = document.getElementById('patient2NameInput');
    const pat1TasksList = document.getElementById('pat1Tasks');
    const pat2TasksList = document.getElementById('pat2Tasks');

    // Buttons
    const addNewWeekButton = document.getElementById('addNewWeekButton');
    const saveAllDataButton = document.getElementById('saveAllDataButton');
    const downloadDataButton = document.getElementById('downloadDataButton');
    const uploadDataInput = document.getElementById('uploadDataInput');
    const deleteWeekButton = document.getElementById('deleteWeekButton');

    // --- HELPER FUNCTIONS ---
    const generateUniqueId = () => `id_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`;

    const getTaskCompletion = (patientTasks) => {
        if (!patientTasks) return { completed: 0, total: TASKS_DEFINITION.length, percentage: 0 };
        const totalTasks = TASKS_DEFINITION.length;
        let completedTasks = 0;
        TASKS_DEFINITION.forEach(taskDef => {
            if (patientTasks[taskDef.id]) {
                completedTasks++;
            }
        });
        return {
            completed: completedTasks,
            total: totalTasks,
            percentage: totalTasks > 0 ? Math.round((completedTasks / totalTasks) * 100) : 0
        };
    };

    // --- DATA MANAGEMENT ---
    function saveAllDataToLocalStorage() {
        localStorage.setItem(LOCAL_STORAGE_KEY, JSON.stringify(appData));
        console.log('All application data saved to localStorage');
    }

    function loadAllDataFromLocalStorage() {
        let savedData = localStorage.getItem(LOCAL_STORAGE_KEY);
        let migrated = false;

        if (!savedData) {
            const oldDataString = localStorage.getItem(OLD_LOCAL_STORAGE_KEY);
            if (oldDataString) {
                try {
                    const oldWeeksData = JSON.parse(oldDataString);
                    if (Array.isArray(oldWeeksData)) {
                        appData.weeks = oldWeeksData;
                        appData.general = { todos: [], notes: "" };
                        appData.weeks.forEach(week => {
                            if (!week.patients) {
                                week.patients = [
                                    { name: "Pat. 1", tasks: {} },
                                    { name: "Pat. 2", tasks: {} }
                                ];
                            }
                             [0,1].forEach(pIndex => {
                                if (!week.patients[pIndex]) { 
                                    week.patients[pIndex] = { name: `Pat. ${pIndex+1}`, tasks: {} };
                                }
                                if (!week.patients[pIndex].tasks) week.patients[pIndex].tasks = {};
                                TASKS_DEFINITION.forEach(taskDef => {
                                    if(typeof week.patients[pIndex].tasks[taskDef.id] === 'undefined') {
                                        week.patients[pIndex].tasks[taskDef.id] = false;
                                    }
                                });
                            });
                        });
                        saveAllDataToLocalStorage();
                        localStorage.removeItem(OLD_LOCAL_STORAGE_KEY);
                        migrated = true;
                        console.log('Data migrated from old format.');
                    }
                } catch (e) {
                    console.error('Error migrating old data:', e);
                }
            }
        }

        if (savedData && !migrated) {
             try {
                const parsedData = JSON.parse(savedData);
                appData.weeks = Array.isArray(parsedData.weeks) ? parsedData.weeks : [];
                appData.general = (typeof parsedData.general === 'object' && parsedData.general !== null) 
                                  ? parsedData.general 
                                  : { todos: [], notes: "" };
                appData.general.todos = Array.isArray(appData.general.todos) ? appData.general.todos : [];
                appData.general.notes = typeof appData.general.notes === 'string' ? appData.general.notes : "";

                appData.weeks.forEach(week => {
                    if (!week.patients) {
                        week.patients = [
                            { name: "Pat. 1", tasks: {} },
                            { name: "Pat. 2", tasks: {} }
                        ];
                    }
                    [0,1].forEach(pIndex => {
                        if (!week.patients[pIndex]) { 
                             week.patients[pIndex] = { name: `Pat. ${pIndex+1}`, tasks: {} };
                        }
                        if (!week.patients[pIndex].tasks) week.patients[pIndex].tasks = {};
                        TASKS_DEFINITION.forEach(taskDef => {
                            if(typeof week.patients[pIndex].tasks[taskDef.id] === 'undefined') {
                                week.patients[pIndex].tasks[taskDef.id] = false;
                            }
                        });
                    });
                });
                console.log('All application data loaded from localStorage');
            } catch (e) {
                console.error('Error parsing application data from localStorage:', e);
                appData = { weeks: [], general: { todos: [], notes: "" } };
                localStorage.removeItem(LOCAL_STORAGE_KEY);
            }
        }
    }
    
    // --- RENDERING FUNCTIONS ---
    function renderGeneralTodos() {
        generalTodoList.innerHTML = '';
        if (!appData.general || !appData.general.todos) return;

        appData.general.todos.forEach(todo => {
            const li = document.createElement('li');
            li.dataset.todoId = todo.id;
            li.innerHTML = `
                <input type="checkbox" id="todo-${todo.id}" ${todo.completed ? 'checked' : ''}>
                <label for="todo-${todo.id}">${escapeAttr(todo.text)}</label>
                <button class="delete-todo" title="Todo löschen">X</button>
            `;
            const checkbox = li.querySelector('input[type="checkbox"]');
            checkbox.addEventListener('change', (e) => handleTodoToggle(todo.id, e.target.checked));
            
            const deleteButton = li.querySelector('.delete-todo');
            deleteButton.addEventListener('click', () => handleDeleteTodo(todo.id));

            generalTodoList.appendChild(li);
        });
    }

    function renderGeneralNotes() {
        if (appData.general) {
            generalNotesTextarea.value = appData.general.notes || "";
        }
    }

    function renderOverview() {
        overviewContent.innerHTML = '';
        if (appData.weeks.length === 0) {
            overviewContent.innerHTML = '<p>Noch keine Wochen angelegt. Fügen Sie eine neue Woche hinzu!</p>';
            return;
        }

        const table = document.createElement('table');
        table.innerHTML = `
            <thead>
                <tr>
                    <th>Wochen Nr.</th>
                    <th>Patient 1 - Fortschritt</th>
                    <th>Patient 2 - Fortschritt</th>
                    <th>Gesamtfortschritt Woche</th>
                </tr>
            </thead>
        `;
        const tbody = document.createElement('tbody');
        appData.weeks.slice().reverse().forEach(week => {
            const p1Completion = getTaskCompletion(week.patients[0].tasks);
            const p2Completion = getTaskCompletion(week.patients[1].tasks);
            const totalCompletedTasks = p1Completion.completed + p2Completion.completed;
            const totalPossibleTasks = p1Completion.total + p2Completion.total;
            const weekOverallPercentage = totalPossibleTasks > 0 ? Math.round((totalCompletedTasks / totalPossibleTasks) * 100) : 0;

            const row = tbody.insertRow();
            row.classList.add('week-row');
            if (weekOverallPercentage === 100) row.classList.add('completed-100');

            row.insertCell().textContent = week.weekNumber || 'N/A';

            const p1Cell = row.insertCell();
            p1Cell.innerHTML = `
                <div class="progress-bar-container" title="${escapeAttr(week.patients[0].name)}: ${p1Completion.completed}/${p1Completion.total}" >
                    <div class="progress-bar" style="width: ${p1Completion.percentage}%;">
                         <a href="#" class="patient-link" data-week-id="${week.id}" data-patient-index="0">
                            ${escapeAttr(week.patients[0].name)} - ${p1Completion.percentage}%
                        </a>
                    </div>
                </div>
            `;

            const p2Cell = row.insertCell();
            p2Cell.innerHTML = `
                <div class="progress-bar-container" title="${escapeAttr(week.patients[1].name)}: ${p2Completion.completed}/${p2Completion.total}">
                    <div class="progress-bar" style="width: ${p2Completion.percentage}%;">
                        <a href="#" class="patient-link" data-week-id="${week.id}" data-patient-index="1">
                            ${escapeAttr(week.patients[1].name)} - ${p2Completion.percentage}%
                        </a>
                    </div>
                </div>
            `;
            const overallCell = row.insertCell();
             overallCell.innerHTML = `
                <div class="progress-bar-container" title="Gesamt: ${totalCompletedTasks}/${totalPossibleTasks}">
                    <div class="progress-bar" style="width: ${weekOverallPercentage}%; background-color: ${weekOverallPercentage === 100 ? '#28a745' : '#007bff'};">${weekOverallPercentage}%</div>
                </div>
            `;
        });
        table.appendChild(tbody);
        overviewContent.appendChild(table);
    }

    function populateWeekSelector() {
        const previousSelectedValue = weekSelector.value;
        weekSelector.innerHTML = '<option value="">-- Keine Woche ausgewählt --</option>';
        appData.weeks.forEach(week => {
            const option = document.createElement('option');
            option.value = week.id;
            option.textContent = `Woche ${week.weekNumber || 'Unbenannt'} (ID: ...${week.id.slice(-4)})`;
            weekSelector.appendChild(option);
        });
        if (appData.weeks.find(w => w.id === previousSelectedValue)) {
            weekSelector.value = previousSelectedValue;
        } else {
            currentWeekId = null;
        }
    }

    function renderCurrentWeekDetails() {
        if (!currentWeekId) {
            currentWeekContentDiv.style.display = 'none';
            currentWeekNumberInput.value = '';
            patient1NameInput.value = '';
            patient2NameInput.value = '';
            pat1TasksList.innerHTML = '';
            pat2TasksList.innerHTML = '';
            return;
        }

        const week = appData.weeks.find(w => w.id === currentWeekId);
        if (!week) {
            console.error('Selected week not found:', currentWeekId);
            currentWeekId = null;
            renderCurrentWeekDetails();
            return;
        }

        currentWeekContentDiv.style.display = 'block';
        currentWeekNumberInput.value = week.weekNumber || '';
        patient1NameInput.value = week.patients[0].name;
        patient2NameInput.value = week.patients[1].name;

        renderPatientTasks(pat1TasksList, week.patients[0], 0, week.id);
        renderPatientTasks(pat2TasksList, week.patients[1], 1, week.id);
    }

    function renderPatientTasks(listElement, patientData, patientIndex, weekId) {
        listElement.innerHTML = '';
        TASKS_DEFINITION.forEach(taskDef => {
            const li = document.createElement('li');
            const checkboxId = `cb-${weekId}-p${patientIndex}-${taskDef.id}`;
            const isChecked = patientData.tasks[taskDef.id] || false;

            let pathLinkHtml = '';
            if (taskDef.path) {
                const escapedPathForAttr = escapeAttr(taskDef.path);
                pathLinkHtml = `<a href="#" class="path-copy-link" data-path="${escapedPathForAttr}" title="Klicken um Pfad zu kopieren: ${escapedPathForAttr}">[Pfad kopieren]</a>`;
            }

            li.innerHTML = `
                <input type="checkbox" id="${checkboxId}" data-taskid="${taskDef.id}" data-patientindex="${patientIndex}" ${isChecked ? 'checked' : ''}>
                <label for="${checkboxId}">${taskDef.desc}</label>
                ${pathLinkHtml}
            `;

            let noteText = '';
            if (patientIndex === 0 && taskDef.notePat1) noteText = taskDef.notePat1;
            else if (patientIndex === 1 && taskDef.notePat2) noteText = taskDef.notePat2;
            else if (taskDef.note) noteText = taskDef.note;

            if (noteText) {
                const smallNote = document.createElement('small');
                smallNote.textContent = noteText;
                li.appendChild(smallNote);
            }
            listElement.appendChild(li);

            document.getElementById(checkboxId).addEventListener('change', handleTaskChange);
        });
    }

    // --- EVENT HANDLERS ---
    function handleAddTodo() {
        const text = addTodoInput.value.trim();
        if (text) {
            const newTodo = {
                id: generateUniqueId(),
                text: text,
                completed: false
            };
            appData.general.todos.push(newTodo);
            addTodoInput.value = '';
            renderGeneralTodos();
            saveAllDataToLocalStorage();
        }
    }

    function handleTodoToggle(todoId, isCompleted) {
        const todo = appData.general.todos.find(t => t.id === todoId);
        if (todo) {
            todo.completed = isCompleted;
            renderGeneralTodos();
            saveAllDataToLocalStorage();
        }
    }

    function handleDeleteTodo(todoId) {
        if (confirm("Möchten Sie dieses Todo wirklich löschen?")) {
            appData.general.todos = appData.general.todos.filter(t => t.id !== todoId);
            renderGeneralTodos();
            saveAllDataToLocalStorage();
        }
    }

    function handleNotesChange() {
        appData.general.notes = generalNotesTextarea.value;
        saveAllDataToLocalStorage();
    }

    function handleAddNewWeek() {
        const newWeekId = generateUniqueId();
        const newWeek = {
            id: newWeekId,
            weekNumber: `Neue Woche ${appData.weeks.length + 1}`,
            patients: [
                { name: "Pat. 1", tasks: TASKS_DEFINITION.reduce((acc, task) => ({ ...acc, [task.id]: false }), {}) },
                { name: "Pat. 2", tasks: TASKS_DEFINITION.reduce((acc, task) => ({ ...acc, [task.id]: false }), {}) }
            ]
        };
        appData.weeks.push(newWeek);
        currentWeekId = newWeekId;
        
        saveAllDataToLocalStorage();
        populateWeekSelector();
        weekSelector.value = newWeekId;
        renderCurrentWeekDetails();
        renderOverview();
        currentWeekNumberInput.focus();
    }
    
    function handleWeekSelectionChange() {
        currentWeekId = weekSelector.value;
        if (!currentWeekId) {
            currentWeekContentDiv.style.display = 'none';
            return;
        }
        renderCurrentWeekDetails();
    }

    function handleCurrentWeekInputChange() {
        if (!currentWeekId) return;
        const week = appData.weeks.find(w => w.id === currentWeekId);
        if (week) {
            week.weekNumber = currentWeekNumberInput.value;
            populateWeekSelector(); 
            weekSelector.value = currentWeekId; 
        }
    }
    
    function handlePatientNameChange(event) {
        if (!currentWeekId) return;
        const week = appData.weeks.find(w => w.id === currentWeekId);
        if (week) {
            const patientIndex = event.target.id === 'patient1NameInput' ? 0 : 1;
            week.patients[patientIndex].name = event.target.value;
        }
    }

    function handleTaskChange(event) {
        if (!currentWeekId) return;
        const week = appData.weeks.find(w => w.id === currentWeekId);
        if (week) {
            const taskId = event.target.dataset.taskid;
            const patientIndex = parseInt(event.target.dataset.patientindex);
            week.patients[patientIndex].tasks[taskId] = event.target.checked;
            saveAllDataToLocalStorage();
            renderOverview();
        }
    }

    function handleDeleteWeek() {
        if (!currentWeekId) {
            alert("Bitte wählen Sie zuerst eine Woche zum Löschen aus.");
            return;
        }
        const week = appData.weeks.find(w => w.id === currentWeekId);
        if (!week) {
             alert("Ausgewählte Woche nicht gefunden.");
             return;
        }

        if (confirm(`Möchten Sie Woche "${week.weekNumber || 'Unbenannt'}" wirklich unwiderruflich löschen?`)) {
            appData.weeks = appData.weeks.filter(w => w.id !== currentWeekId);
            currentWeekId = null;
            
            saveAllDataToLocalStorage();
            populateWeekSelector();
            renderCurrentWeekDetails();
            renderOverview();
            alert("Woche gelöscht.");
        }
    }
    
    function handleDownloadData() {
        if (currentWeekId) {
            const currentWeek = appData.weeks.find(w => w.id === currentWeekId);
            if (currentWeek) {
                currentWeek.weekNumber = currentWeekNumberInput.value;
                currentWeek.patients[0].name = patient1NameInput.value;
                currentWeek.patients[1].name = patient2NameInput.value;
            }
        }
        const dataStr = JSON.stringify(appData, null, 2);
        const dataBlob = new Blob([dataStr], {type: "application/json"});
        const url = URL.createObjectURL(dataBlob);
        const link = document.createElement('a');
        link.href = url;
        const timestamp = new Date().toISOString().slice(0,10);
        link.download = `epilepsie_checkliste_backup_${timestamp}.json`;
        document.body.appendChild(link);
        link.click();
        document.body.removeChild(link);
        URL.revokeObjectURL(url);
        alert('Alle Daten wurden heruntergeladen!');
    }

    function handleUploadData(event) {
        const file = event.target.files[0];
        if (!file) return;
        const reader = new FileReader();
        reader.onload = function(e) {
            try {
                const importedRawData = JSON.parse(e.target.result);
                let importedAppData = { weeks: [], general: { todos: [], notes: "" } };

                if (Array.isArray(importedRawData)) { 
                    importedAppData.weeks = importedRawData;
                } else if (typeof importedRawData === 'object' && importedRawData !== null) { 
                    importedAppData.weeks = Array.isArray(importedRawData.weeks) ? importedRawData.weeks : [];
                    if (typeof importedRawData.general === 'object' && importedRawData.general !== null) {
                        importedAppData.general.todos = Array.isArray(importedRawData.general.todos) ? importedRawData.general.todos : [];
                        importedAppData.general.notes = typeof importedRawData.general.notes === 'string' ? importedRawData.general.notes : "";
                    }
                } else {
                    alert('Fehler: Die Datei hat kein unterstütztes Format (weder Array noch Objekt).');
                    uploadDataInput.value = '';
                    return;
                }

                importedAppData.weeks.forEach(week => {
                    if (!week.id) week.id = generateUniqueId();
                    if (!week.patients || week.patients.length < 2) {
                        week.patients = [
                            { name: week.patients?.[0]?.name || "Pat. 1", tasks: week.patients?.[0]?.tasks || TASKS_DEFINITION.reduce((acc, task) => ({ ...acc, [task.id]: false }), {}) },
                            { name: week.patients?.[1]?.name || "Pat. 2", tasks: week.patients?.[1]?.tasks || TASKS_DEFINITION.reduce((acc, task) => ({ ...acc, [task.id]: false }), {}) }
                        ];
                    }
                     [0,1].forEach(pIndex => {
                         if (!week.patients[pIndex]) { 
                             week.patients[pIndex] = { name: `Pat. ${pIndex+1}`, tasks: {} };
                         }
                         if (!week.patients[pIndex].tasks) week.patients[pIndex].tasks = {};
                         TASKS_DEFINITION.forEach(taskDef => {
                            if(typeof week.patients[pIndex].tasks[taskDef.id] === 'undefined') {
                                week.patients[pIndex].tasks[taskDef.id] = false;
                            }
                        });
                    });
                });

                importedAppData.general.todos.forEach(todo => {
                    if (!todo.id) todo.id = generateUniqueId();
                    if (typeof todo.completed === 'undefined') todo.completed = false;
                    if (typeof todo.text !== 'string') todo.text = String(todo.text || 'Unbenanntes Todo');
                });

                appData = importedAppData; 
                currentWeekId = null; 

                saveAllDataToLocalStorage();
                renderGeneralTodos();
                renderGeneralNotes();
                populateWeekSelector();
                renderCurrentWeekDetails();
                renderOverview();
                alert('Daten erfolgreich hochgeladen und angewendet!');

            } catch (error) {
                alert('Fehler beim Lesen oder Verarbeiten der Datei: ' + error.message);
            }
            uploadDataInput.value = ''; 
        };
        reader.onerror = () => alert('Fehler beim Lesen der Datei.');
        reader.readAsText(file);
    }

    function setupPathCopyListeners() {
        [pat1TasksList, pat2TasksList].forEach(listElement => {
            listElement.addEventListener('click', function(event) {
                const linkElement = event.target.closest('.path-copy-link');
                if (linkElement) {
                    event.preventDefault();
                    const path = linkElement.dataset.path;
                    if (path) {
                        navigator.clipboard.writeText(path)
                            .then(() => {
                                showTemporaryMessage(linkElement, 'Kopiert!', 1500);
                            })
                            .catch(err => {
                                console.error('Failed to copy path to clipboard: ', err);
                                try {
                                    window.prompt("Konnte nicht automatisch kopieren. Bitte manuell kopieren:", path);
                                } catch (promptErr) {
                                    alert('Fehler beim Kopieren des Pfades. Siehe Konsole für Details.');
                                }
                            });
                    }
                }
            });
        });
    }

    // Event listener for patient name clicks in the overview table
    function handlePatientLinkClick(event) {
        const target = event.target.closest('.patient-link');
        if (!target) return;

        event.preventDefault(); // Prevent default anchor behavior

        const weekId = target.dataset.weekId;
        // const patientIndex = parseInt(target.dataset.patientIndex, 10); // Patient index might be useful later

        if (weekId) {
            currentWeekId = weekId;
            populateWeekSelector(); // Update dropdown options
            weekSelector.value = weekId; // Select the correct week in the dropdown
            renderCurrentWeekDetails(); // Render the details for this week

            // Scroll to the "Woche Details" section
            if (currentWeekSection) {
                currentWeekSection.scrollIntoView({ behavior: 'smooth' });
            }
        }
    }

    // --- INITIALIZATION ---
    function init() {
        loadAllDataFromLocalStorage();
        
        renderGeneralTodos();
        renderGeneralNotes();

        populateWeekSelector();
        renderOverview();
        
        if (weekSelector.value) { 
             currentWeekId = weekSelector.value;
             handleWeekSelectionChange(); // Initial render if a week is pre-selected
        }

        addTodoButton.addEventListener('click', handleAddTodo);
        addTodoInput.addEventListener('keypress', (e) => {
            if (e.key === 'Enter') handleAddTodo();
        });
        generalNotesTextarea.addEventListener('blur', handleNotesChange);

        addNewWeekButton.addEventListener('click', handleAddNewWeek);
        weekSelector.addEventListener('change', handleWeekSelectionChange);
        
        currentWeekNumberInput.addEventListener('blur', () => { handleCurrentWeekInputChange(); saveAllDataToLocalStorage(); renderOverview(); });
        patient1NameInput.addEventListener('blur', (event) => { handlePatientNameChange(event); saveAllDataToLocalStorage(); renderOverview(); });
        patient2NameInput.addEventListener('blur', (event) => { handlePatientNameChange(event); saveAllDataToLocalStorage(); renderOverview(); });

        saveAllDataButton.addEventListener('click', () => {
            if (currentWeekId) {
                const currentWeek = appData.weeks.find(w => w.id === currentWeekId);
                if (currentWeek) {
                    currentWeek.weekNumber = currentWeekNumberInput.value;
                    currentWeek.patients[0].name = patient1NameInput.value;
                    currentWeek.patients[1].name = patient2NameInput.value;
                }
            }
            saveAllDataToLocalStorage();
            renderOverview();
            alert('Alle Daten manuell in localStorage gespeichert!');
        });
        downloadDataButton.addEventListener('click', handleDownloadData);
        uploadDataInput.addEventListener('change', handleUploadData);
        deleteWeekButton.addEventListener('click', handleDeleteWeek);

        setupPathCopyListeners();

        // Add event listener for clicks on patient links in the overview
        if (overviewContent) {
            overviewContent.addEventListener('click', handlePatientLinkClick);
        }
    }

    init();
});