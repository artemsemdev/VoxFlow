// VoxFlow JS Interop for Blazor
window.voxFlowInterop = {
    // Initialize drop zone with file path extraction
    initDropZone: function (elementId, dotNetRef) {
        const el = document.getElementById(elementId);
        if (!el) return;

        el.addEventListener('drop', async (e) => {
            e.preventDefault();
            el.classList.remove('drag-over');

            // In MAUI Blazor Hybrid, dropped files come through the DataTransfer API
            if (e.dataTransfer && e.dataTransfer.files && e.dataTransfer.files.length > 0) {
                const file = e.dataTransfer.files[0];
                // In a WebView2/WKWebView context, file.name is available
                // The actual path resolution happens through MAUI's platform layer
                await dotNetRef.invokeMethodAsync('OnFileDropped', file.name);
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
        // This will be handled by MAUI Launcher.OpenAsync via C# interop
        // The JS side just triggers the C# call
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
