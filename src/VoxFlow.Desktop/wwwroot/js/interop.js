// VoxFlow JS Interop for Blazor
window.voxFlowInterop = {
    initDropZone: function (elementId, inputId) {
        const el = document.getElementById(elementId);
        const input = document.getElementById(inputId);
        if (!el || !input || el.dataset.dropZoneInitialized === '1') return;

        el.dataset.dropZoneInitialized = '1';

        const assignFiles = (files) => {
            try {
                input.files = files;
                return input.files && input.files.length > 0;
            } catch {
            }

            try {
                const dataTransfer = new DataTransfer();
                for (const file of files) {
                    dataTransfer.items.add(file);
                }

                input.files = dataTransfer.files;
                return input.files && input.files.length > 0;
            } catch {
                return false;
            }
        };

        el.addEventListener('drop', async (e) => {
            e.preventDefault();
            el.classList.remove('drag-over');

            if (el.getAttribute('aria-disabled') === 'true') {
                return;
            }

            if (e.dataTransfer && e.dataTransfer.files && e.dataTransfer.files.length > 0) {
                if (assignFiles(e.dataTransfer.files)) {
                    input.dispatchEvent(new Event('change', { bubbles: true }));
                }
            }
        });

        el.addEventListener('dragover', (e) => {
            e.preventDefault();
            el.classList.add('drag-over');
        });

        el.addEventListener('dragenter', (e) => {
            e.preventDefault();
            el.classList.add('drag-over');
        });

        el.addEventListener('dragleave', (e) => {
            el.classList.remove('drag-over');
        });
    },

    // Open a folder in Finder
    openInFinder: function (path) {
        return true;
    },

    // Copy text to clipboard
    copyToClipboard: async function (text) {
        try {
            await navigator.clipboard.writeText(text);
            return true;
        } catch {
            // Fallback for older WebView
            const textarea = document.createElement('textarea');
            textarea.value = text;
            document.body.appendChild(textarea);
            textarea.select();
            document.execCommand('copy');
            document.body.removeChild(textarea);
            return true;
        }
    }
};
