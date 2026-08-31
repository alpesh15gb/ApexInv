import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:apexbooks/services/vyapar_import_service.dart';

class ImportScreen extends ConsumerStatefulWidget {
  const ImportScreen({super.key});

  @override
  ConsumerState<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends ConsumerState<ImportScreen> {
  VyaparPreview? _preview;
  VyaparImportResult? _result;
  bool _isLoading = false;
  bool _isImporting = false;
  String? _vypPath;
  String? _error;
  String _progressMessage = '';

  Future<void> _pickFile() async {
    try {
      // FileType.any + code-side validation: .vyb has no registered MIME
      // type on Android, so FileType.custom with allowedExtensions can
      // grey the file out in the system picker.
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
      );
      if (result == null || result.files.isEmpty) return;

      setState(() {
        _isLoading = true;
        _error = null;
        _preview = null;
        _result = null;
      });

      final file = result.files.first;
      if (file.extension?.toLowerCase() != 'vyb') {
        setState(() {
          _error = 'Please select a Vyapar .vyb backup file.';
          _isLoading = false;
        });
        return;
      }

      // file_picker only fills `bytes` on web; on Android/desktop the data
      // must be read from the (already copied) file path instead.
      Uint8List? bytes = file.bytes;
      if (bytes == null && file.path != null) {
        bytes = await File(file.path!).readAsBytes();
      }
      if (bytes == null) {
        setState(() {
          _error = 'Could not read file';
          _isLoading = false;
        });
        return;
      }

      final tempDir = await getTemporaryDirectory();
      final vypPath = await VyaparImportService.extractVypFile(bytes, tempDir.path);
      final preview = await VyaparImportService.preview(vypPath);

      setState(() {
        _vypPath = vypPath;
        _preview = preview;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Error reading file: $e';
        _isLoading = false;
      });
    }
  }

  Future<void> _startImport() async {
    if (_vypPath == null) return;

    setState(() {
      _isImporting = true;
      _error = null;
      _result = null;
      _progressMessage = 'Starting import...';
    });

    try {
      final result = await VyaparImportService.importFromVyp(
        _vypPath!,
        onProgress: (msg) {
          if (mounted) setState(() => _progressMessage = msg);
        },
      );
      setState(() {
        _result = result;
        _isImporting = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Import failed: $e';
        _isImporting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Import from Vyapar'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.upload_file, color: colorScheme.primary, size: 32),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Import Vyapar Backup',
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Import customers, products, and invoices from a Vyapar .vyb backup file.',
                                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _isLoading ? null : _pickFile,
                        icon: _isLoading
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.folder_open),
                        label: Text(_isLoading ? 'Reading file...' : 'Select .vyb File'),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 16),

            // Error
            if (_error != null)
              Card(
                color: colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Icon(Icons.error_outline, color: colorScheme.error),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _error!,
                          style: TextStyle(color: colorScheme.onErrorContainer),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            // Preview
            if (_preview != null && !_isImporting && _result == null)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Preview',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      if (_preview!.firmName.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          'Company: ${_preview!.firmName}',
                          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                      const SizedBox(height: 16),
                      _buildPreviewRow(Icons.people, 'Customers', _preview!.customerCount),
                      _buildPreviewRow(Icons.inventory_2, 'Products', _preview!.productCount),
                      _buildPreviewRow(Icons.receipt_long, 'Invoices', _preview!.invoiceCount),
                      if (_preview!.vendorCount > 0)
                        _buildPreviewRow(Icons.local_shipping, 'Vendors', _preview!.vendorCount),
                      const SizedBox(height: 20),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _startImport,
                          icon: const Icon(Icons.download),
                          label: const Text('Start Import'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            // Progress
            if (_isImporting)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: [
                      const CircularProgressIndicator(),
                      const SizedBox(height: 16),
                      Text(
                        _progressMessage,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
              ),

            // Result
            if (_result != null)
              Card(
                color: colorScheme.primaryContainer.withValues(alpha: 0.3),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.check_circle, color: Colors.green, size: 28),
                          const SizedBox(width: 12),
                          Text(
                            'Import Complete!',
                            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      _buildResultRow('Customers imported', _result!.customersImported),
                      _buildResultRow('Customers skipped', _result!.customersSkipped),
                      _buildResultRow('Products imported', _result!.productsImported),
                      _buildResultRow('Products skipped', _result!.productsSkipped),
                      _buildResultRow('Invoices imported', _result!.invoicesImported),
                      _buildResultRow('Invoices skipped', _result!.invoicesSkipped),
                      if (_result!.warnings.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        Text(
                          'Warnings (${_result!.warnings.length})',
                          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            color: Colors.orange.shade800,
                          ),
                        ),
                        const SizedBox(height: 8),
                        ...(_result!.warnings.take(10).map((w) => Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(
                            '• $w',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ))),
                        if (_result!.warnings.length > 10)
                          Text(
                            '... and ${_result!.warnings.length - 10} more',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                      ],
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Done'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            // Instructions
            if (_preview == null && !_isLoading && _result == null) ...[
              const SizedBox(height: 24),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'How to get a .vyb file',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 12),
                      _buildInstructionStep(1, 'Open the Vyapar app'),
                      _buildInstructionStep(2, 'Go to Settings → Data Backup & Restore'),
                      _buildInstructionStep(3, 'Tap "Create Backup" to generate a .vyb file'),
                      _buildInstructionStep(4, 'Transfer the file to this computer'),
                      _buildInstructionStep(5, 'Click "Select .vyb File" above'),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildPreviewRow(IconData icon, String label, int count) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(child: Text(label)),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              count.toString(),
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResultRow(String label, int count) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label),
          Text(
            count.toString(),
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  Widget _buildInstructionStep(int number, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          CircleAvatar(
            radius: 12,
            backgroundColor: Theme.of(context).colorScheme.primaryContainer,
            child: Text(
              number.toString(),
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}
