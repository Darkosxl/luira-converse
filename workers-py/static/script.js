// static/script.js
const chatbox = document.getElementById('chatbox');
const userInput = document.getElementById('userInput');
const sendButton = document.getElementById('sendButton');

// Initialize markdown-it
const md = window.markdownit();
// DOMPurify is available globally via CDN or local include

// --- Constants ---
const OPTIONS_PAGE_SIZE_JS = 75; // Should match OPTIONS_PAGE_SIZE in Python


// --- Renders a single page of options data with pagination controls ---
// Arguments:
//   pageData: Object received from /get_options (contains options, total_pages, current_page etc.)
//   targetDiv: The specific DIV within the message bubble where the list should be rendered
//   optionsMetadata: Original metadata from the chat response (contains title, col_name, option_type etc.)
function renderPaginatedOptionsList(pageData, targetDiv, optionsMetadata) {
    const options = pageData.options || [];
    const totalPages = pageData.total_pages || 1;
    const currentPage = pageData.current_page || 1;
    const optionType = optionsMetadata.option_type; // Needed for subsequent API calls
    const title = optionsMetadata.title || 'Available Options:';
    const colName = optionsMetadata.col_name || 'Option';

    // --- Clear previous content and build structure ---
    targetDiv.innerHTML = ''; // Clear loading message or previous page

    const titleElement = document.createElement('div');
    titleElement.classList.add('options-title');
    titleElement.textContent = title;
    targetDiv.appendChild(titleElement);

    const tableContainer = document.createElement('div');
    tableContainer.classList.add('options-table-container');
    targetDiv.appendChild(tableContainer);

    const table = document.createElement('table');
    const thead = document.createElement('thead');
    const tbody = document.createElement('tbody');
    table.appendChild(thead);
    table.appendChild(tbody);
    tableContainer.appendChild(table);

    const headerRow = document.createElement('tr');
    const th = document.createElement('th');
    th.textContent = colName;
    headerRow.appendChild(th);
    thead.appendChild(headerRow);

    const controlsDiv = document.createElement('div');
    controlsDiv.classList.add('pagination-controls');
    targetDiv.appendChild(controlsDiv); // Append controls after table container

    // --- Populate table body ---
    if (options.length === 0) {
        const row = document.createElement('tr');
        const cell = document.createElement('td');
        cell.textContent = optionsMetadata.message || "No options available.";
        cell.style.fontStyle = 'italic';
        row.appendChild(cell);
        tbody.appendChild(row);
    } else {
        options.forEach(option => {
            const row = document.createElement('tr');
            const cell = document.createElement('td');
            cell.textContent = option;
            row.appendChild(cell);
            tbody.appendChild(row);
        });
    }

    // --- Add Pagination Controls (if multiple pages) ---
    if (totalPages > 1) {
        const prevButton = document.createElement('button');
        prevButton.textContent = '◀ Previous';
        prevButton.classList.add('pagination-button');
        prevButton.disabled = currentPage <= 1;

        const pageInfo = document.createElement('span');
        pageInfo.classList.add('page-info');
        pageInfo.textContent = `Page ${currentPage} of ${totalPages}`;

        const nextButton = document.createElement('button');
        nextButton.textContent = 'Next ▶';
        nextButton.classList.add('pagination-button');
        nextButton.disabled = currentPage >= totalPages;

        controlsDiv.appendChild(prevButton);
        controlsDiv.appendChild(pageInfo);
        controlsDiv.appendChild(nextButton);

        // --- Event Listeners for fetching other pages ---
        async function fetchAndRenderPage(pageNumber) {
            prevButton.disabled = true;
            nextButton.disabled = true;
            pageInfo.textContent = `Loading page ${pageNumber}...`;

            try {
                const response = await fetch(`/get_options?type=${optionType}&page=${pageNumber}&size=${OPTIONS_PAGE_SIZE_JS}`);
                if (!response.ok) {
                    throw new Error(`HTTP error! status: ${response.status}`);
                }
                const newPageData = await response.json();
                // Re-render the targetDiv with the new data
                renderPaginatedOptionsList(newPageData, targetDiv, optionsMetadata);
                // Scroll containing message bubble into view if needed (optional)
                 targetDiv.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
            } catch (error) {
                console.error(`Error fetching page ${pageNumber} for ${optionType}:`, error);
                pageInfo.textContent = "Error loading page.";
                // Optionally re-enable buttons based on the last known state
                prevButton.disabled = currentPage <= 1;
                nextButton.disabled = currentPage >= totalPages;
            }
        }

        prevButton.addEventListener('click', () => {
            if (currentPage > 1) {
                fetchAndRenderPage(currentPage - 1);
            }
        });

        nextButton.addEventListener('click', () => {
            if (currentPage < totalPages) {
                fetchAndRenderPage(currentPage + 1);
            }
        });
    } else {
        // No controls needed for a single page
        controlsDiv.remove(); // Remove empty controls div if it exists
    }

    // Scroll the *table container* itself to the top (useful if page content changes)
    tableContainer.scrollTop = 0;
}


// --- Adds a message bubble to the chatbox ---
// Handles text, markdown tables, and potentially paginated lists
async function addMessage(sender, textMessage, optionsData = null) {
    const messageDiv = document.createElement('div');
    messageDiv.classList.add('message', sender);
    let messageAppendedEarly = false; // Flag to check if appended during async loading

    if (sender === 'assistant') {
        console.log("--- addMessage (assistant) ---");
        console.log("Type of textMessage:", typeof textMessage);
        // console.log("Value of textMessage:", textMessage); // Can be long
        console.log("Type of optionsData:", typeof optionsData);
        console.log("Value of optionsData:", optionsData);

        // --- 1. Render the primary text content ---
        const messageString = (typeof textMessage === 'string') ? textMessage : JSON.stringify(textMessage);
        let textContentDiv;
        try {
            const textHtml = md.render(messageString);
            const cleanTextHtml = DOMPurify.sanitize(textHtml);
            textContentDiv = document.createElement('div'); // Container for text
            textContentDiv.innerHTML = cleanTextHtml;
            messageDiv.appendChild(textContentDiv); // Add text part first
        } catch(e) {
            console.error("Error rendering text part:", e);
            textContentDiv = document.createElement('div'); // Fallback text container
            textContentDiv.textContent = messageString;
            messageDiv.appendChild(textContentDiv);
        }

        // --- 2. Handle optionsData (potential lists/tables) ---
        // MODIFIED LOGIC HERE: If optionsData exists and is a list, always fetch page 1
        if (optionsData && optionsData.is_options_list === true) {
            const optionsContainerDiv = document.createElement('div');
            optionsContainerDiv.classList.add('options-list-wrapper');
            optionsContainerDiv.textContent = "Loading options..."; // Placeholder
            messageDiv.appendChild(optionsContainerDiv); // Add container with placeholder

            // Append the whole message bubble NOW so user sees the text & loading indicator
            chatbox.appendChild(messageDiv);
            chatbox.scrollTop = chatbox.scrollHeight;
            messageAppendedEarly = true; // Set flag

            console.log(`Options list requested (${optionsData.option_type}), fetching first page...`);

            try {
                // ALWAYS Fetch page 1 data from the backend, regardless of pagination flag in metadata
                const response = await fetch(`/get_options?type=${optionsData.option_type}&page=1&size=${OPTIONS_PAGE_SIZE_JS}`);
                if (!response.ok) {
                     // Try to get error message from response body if available
                     let errorDetail = `HTTP ${response.status}`;
                     try {
                         const errorJson = await response.json();
                         errorDetail += `: ${errorJson.error || 'Unknown error from API'}`;
                     } catch (_) { /* Ignore if response wasn't JSON */ }
                     throw new Error(errorDetail);
                }
                const firstPageData = await response.json();

                // Render the fetched data into the container DIV
                // renderPaginatedOptionsList handles showing controls only if total_pages > 1
                renderPaginatedOptionsList(firstPageData, optionsContainerDiv, optionsData);

                // Scroll again after list content is loaded
                setTimeout(() => { chatbox.scrollTop = chatbox.scrollHeight; }, 50);

            } catch (error) {
                console.error(`Error fetching first page for ${optionsData.option_type}:`, error);
                optionsContainerDiv.textContent = `Error loading options: ${error.message || 'Unknown error'}`;
            }
        // REMOVED the old 'else if (Array.isArray(optionsData.options))' block

        } else { // No options data, just handle potential tables in text
             // --- 3. Handle potential Markdown tables within the text content ---
             // ... (keep table wrapping logic as is) ...
             const tables = textContentDiv.querySelectorAll('table');
             tables.forEach(table => {
                 if (!table.closest('.scrollable-table-container')) {
                      const scrollWrapper = document.createElement('div');
                      scrollWrapper.classList.add('scrollable-table-container');
                      table.parentNode.insertBefore(scrollWrapper, table);
                      scrollWrapper.appendChild(table);
                 }
             });
        }

    } else { // User message
        messageDiv.textContent = textMessage;
    }

    // --- Append the fully constructed message div to the chatbox ---
    if (!messageAppendedEarly) {
       chatbox.appendChild(messageDiv);
    }

    // --- Scroll chatbox to the bottom ---
    setTimeout(() => {
       chatbox.scrollTop = chatbox.scrollHeight;
    }, 0);
}


// --- Sends user message to backend and handles response ---
async function sendMessage() {
    const message = userInput.value.trim();
    if (message === '') return;

    // Display user message immediately (using non-async part of addMessage)
    await addMessage('user', message); // Await ensures it's added before bot reply appears

    userInput.value = '';
    userInput.disabled = true;
    sendButton.disabled = true;

    try {
        const response = await fetch('/chat', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
            },
            credentials: 'same-origin',
            body: JSON.stringify({ message }),
        });

        // Clone the response. One clone will be used for JSON parsing,
        // and the original can be used for raw text if parsing fails.
        const responseClone = response.clone();

        let responseData;
        try {
             responseData = await response.json();
        } catch (jsonError) {
             console.error("Failed to parse response JSON:", jsonError);
             // Use the clone to get the raw text for debugging
             const textResponse = await responseClone.text();
             console.error("Raw response text:", textResponse);
             if (!response.ok) {
                 throw new Error(`HTTP error! status: ${responseClone.status} - Response not valid JSON`);
             }
                 throw new Error("Received OK status but invalid JSON response.");
        }

        if (!response.ok) {
            let errorMsg = `HTTP error! status: ${response.status}`;
            // Use reply or error from parsed JSON if available
            if (responseData && (responseData.error || responseData.reply)) {
                errorMsg += ` - ${responseData.error || responseData.reply}`;
            }
            throw new Error(errorMsg);
        }

        // Check for the expected 'reply' field
        if (responseData && responseData.reply !== undefined) {
            // Call addMessage (now async) to display assistant response
            // Pass both text reply and potential options data
            await addMessage('assistant', responseData.reply, responseData.options_data);
        } else {
             console.error("Received OK status but 'reply' field missing in response:", responseData);
             throw new Error("Received OK status but 'reply' field missing in response.");
        }

    } catch (error) {
        console.error('Error sending/receiving message:', error);
        // Display error message using addMessage
        await addMessage('assistant', `Sorry, I encountered an error: ${error.message || 'Unknown error'}`);
    } finally {
         // Re-enable input after processing
         userInput.disabled = false;
         sendButton.disabled = false;
         userInput.focus();
    }
}

// --- Event listeners ---
sendButton.addEventListener('click', sendMessage);

userInput.addEventListener('keypress', (event) => {
    // Send message on Enter key, unless Shift+Enter is pressed
    if (event.key === 'Enter' && !event.shiftKey) {
        event.preventDefault(); // Prevent default Enter behavior (new line)
        sendMessage();
    }
});

// Optional: Initial greeting or message
// window.addEventListener('load', () => {
//     addMessage('assistant', "Hi! Ask me about Venture Capital firms.");
// });