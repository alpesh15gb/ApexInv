import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:thermal_printer/thermal_printer.dart';

import 'package:apexbooks/common/breakpoints.dart';
import 'package:apexbooks/common/constants.dart';
import 'package:apexbooks/domain/jewellery/jewellery_calculator.dart';
import 'package:apexbooks/models/jewellery_attributes.dart';
import 'package:apexbooks/models/metal_rate.dart';
import 'package:apexbooks/models/product.dart';
import 'package:apexbooks/providers/industry_provider.dart';
import 'package:apexbooks/providers/repositories.dart';
import 'package:apexbooks/services/label_printing/label_models.dart';
import 'package:apexbooks/services/label_printing/label_printer_service.dart';
import 'package:apexbooks/widgets/app/app.dart';

/// Prints product barcode labels straight to a TSC (TSPL) or Zebra (ZPL)
/// label printer over USB or network (TCP 9100) — no driver, PDF, or PC
/// software in the middle.
class BarcodeLabelsScreen extends ConsumerStatefulWidget {
  const BarcodeLabelsScreen({super.key});

  @override
  ConsumerState<BarcodeLabelsScreen> createState() =>
      _BarcodeLabelsScreenState();
}

class _BarcodeLabelsScreenState extends ConsumerState<BarcodeLabelsScreen> {
  final _service = const LabelPrinterService();
  final _searchController = TextEditingController();

  bool _loading = true;
  String? _loadError;
  List<Product> _products = [];
  String _query = '';
  final Map<String, int> _copies = {};

  // Jewellery tag mode (retail.md P1): when the shop is a jeweller the
  // screen can print tags (purity/weight/price) instead of plain labels.
  bool _isJewellery = false;
  bool _tagMode = false;
  Map<String, JewelleryAttributes> _attributes = {};
  final Map<String, MetalRate?> _rates = {};

  LabelPrinterLanguage _language = LabelPrinterLanguage.tspl;
  LabelPrinterConnection? _connection;
  LabelSize _size = LabelSize.presets.first;
  LabelDesign _design = const LabelDesign();
  bool _customSize = false;
  final _customWidthController = TextEditingController();
  final _customHeightController = TextEditingController();
  String _currencyCode = 'INR';
  bool _printing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _customWidthController.dispose();
    _customHeightController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final isJewellery =
          ref.read(industryProfileProvider) == IndustryProfile.jewellery;
      final results = await Future.wait([
        ref.read(productRepositoryProvider).getAllProducts(),
        _service.getLanguage(),
        _service.getConnection(),
        _service.getSize(),
        _service.getDesign(),
        ref.read(settingsRepositoryProvider).getCurrency(),
        if (isJewellery)
          ref.read(jewelleryRepositoryProvider).getAllAttributes()
        else
          Future.value(const <String, JewelleryAttributes>{}),
      ]);
      if (!mounted) return;
      final size = results[3] as LabelSize;
      setState(() {
        _products = results[0] as List<Product>;
        _language = results[1] as LabelPrinterLanguage;
        _connection = results[2] as LabelPrinterConnection?;
        _size = size;
        _design = results[4] as LabelDesign;
        _customSize = size.isCustom;
        if (size.isCustom) {
          _customWidthController.text = size.widthMm.toString();
          _customHeightController.text = size.heightMm.toString();
        }
        _currencyCode = (results[5] as dynamic).code as String;
        _isJewellery = isJewellery;
        _attributes = results[6] as Map<String, JewelleryAttributes>;
        _loading = false;
      });
      if (isJewellery) await _loadRates();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e.toString();
        _loading = false;
      });
    }
  }

  /// Latest rate per metal+purity pair present on tagged products — tags
  /// carry today's price, invoices freeze the rate they billed with.
  Future<void> _loadRates() async {
    final pairs = <String>{};
    for (final attr in _attributes.values) {
      pairs.add('${attr.metal}|${attr.purity}');
    }
    final repo = ref.read(jewelleryRepositoryProvider);
    final now = DateTime.now();
    final loaded = <String, MetalRate?>{};
    for (final pair in pairs) {
      final parts = pair.split('|');
      loaded[pair] = await repo.getRateForDate(
        metal: parts[0],
        purity: parts[1],
        date: now,
      );
    }
    if (!mounted) return;
    setState(() => _rates
      ..clear()
      ..addAll(loaded));
  }

  List<Product> get _filtered {
    final q = _query.trim().toLowerCase();
    final list = q.isEmpty
        ? _products
        : _products
            .where((p) =>
                p.name.toLowerCase().contains(q) ||
                p.hsncode.toLowerCase().contains(q) ||
                p.barcode.toLowerCase().contains(q))
            .toList();
    return list;
  }

  List<LabelItem> get _selectedItems => [
        for (final p in _products)
          if ((_copies[p.id] ?? 0) > 0)
            LabelItem(product: p, copies: _copies[p.id]!),
      ];

  /// Selected jewellery tags; products without attributes can't be tagged.
  List<TagLabelItem> get _selectedTagItems => [
        for (final p in _products)
          if ((_copies[p.id] ?? 0) > 0 && _attributes[p.id] != null)
            TagLabelItem(
              product: p,
              attributes: _attributes[p.id]!,
              rate: _rates[
                  '${_attributes[p.id]!.metal}|${_attributes[p.id]!.purity}'],
              copies: _copies[p.id]!,
            ),
      ];

  int get _totalLabels =>
      _selectedItems.fold(0, (sum, item) => sum + item.copies);

  Future<void> _updateDesign(LabelDesign design) async {
    await _service.setDesign(design);
    if (!mounted) return;
    setState(() => _design = design);
  }

  Future<void> _applyCustomSize() async {
    final w = double.tryParse(_customWidthController.text.trim());
    final h = double.tryParse(_customHeightController.text.trim());
    if (w == null || h == null || w < 10 || w > 300 || h < 10 || h > 300) {
      return;
    }
    final id = LabelSize.customId(w, h);
    final size = LabelSize.fromId(id);
    if (!size.isCustom) return;
    await _service.setSize(id);
    if (!mounted) return;
    setState(() => _size = size);
  }

  Future<void> _pickPrinter() async {
    final connection = await showDialog<LabelPrinterConnection>(
      context: context,
      builder: (context) => _PrinterPickerDialog(
        service: _service,
        initial: _connection,
      ),
    );
    if (connection == null || !mounted) return;
    await _service.setConnection(connection);
    if (!mounted) return;
    setState(() => _connection = connection);
  }

  Future<void> _print({bool test = false}) async {
    final connection = _connection;
    if (connection == null || !connection.isConfigured) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Choose a label printer first.')),
      );
      await _pickPrinter();
      return;
    }
    final items = test ? const <LabelItem>[] : _selectedItems;
    if (!test && items.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select at least one product.')),
      );
      return;
    }
    setState(() => _printing = true);
    try {
      final String payload;
      if (_tagMode && !test) {
        final tags = _selectedTagItems;
        if (tags.isEmpty) {
          if (!mounted) return;
          setState(() => _printing = false);
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text(
                  'Select jewellery items that have weight and purity set.')));
          return;
        }
        final missingRate =
            tags.any((t) => t.rate == null || t.rate!.sellRatePerGram <= 0);
        if (missingRate) {
          if (!mounted) return;
          setState(() => _printing = false);
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: const Text(
                  'Metal rate required for all jewellery tags. Set rates in Metal Rates first.'),
              behavior: SnackBarBehavior.floating,
              showCloseIcon: true));
          return;
        }
        payload = _service.buildTagJob(
          items: tags,
          language: _language,
          size: _size,
          currencyCode: _currencyCode,
        );
      } else {
        final items = test ? const <LabelItem>[] : _selectedItems;
        if (!test && items.isEmpty) {
          if (!mounted) return;
          setState(() => _printing = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Select at least one product.')),
          );
          return;
        }
        payload = test
            ? _service.buildTestJob(language: _language, size: _size)
            : _service.buildJob(
                items: items,
                language: _language,
                size: _size,
                currencyCode: _currencyCode,
                showPrice: _design.showPrice,
                design: _design,
              );
      }
      final ok =
          await _service.printBytes(connection: connection, payload: payload);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(ok
                ? (test ? 'Test label sent.' : '$_totalLabels label(s) sent.')
                : 'Printer did not accept the job.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Print failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar:
          AppBar(title: Text(_tagMode ? 'Jewellery Tags' : 'Barcode Labels')),
      body: _loading
          ? const AppLoadingState()
          : _loadError != null
              ? AppListStateView(
                  state: AppListState.error,
                  errorMessage: _loadError,
                  onRetry: _load,
                  emptyState: const SizedBox.shrink(),
                  data: const SizedBox.shrink(),
                )
              : LayoutBuilder(builder: (context, constraints) {
                  final wide = constraints.maxWidth >= 980;
                  final form = _optionsColumn();
                  final list = _productList();
                  if (!wide) {
                    return SingleChildScrollView(
                      padding: const EdgeInsets.all(AppPadding.xlarge),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          form,
                          const SizedBox(height: AppPadding.xlarge),
                          list,
                        ],
                      ),
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                          width: 360,
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.all(AppPadding.xlarge),
                            child: form,
                          )),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(
                              0,
                              AppPadding.xlarge,
                              AppPadding.xlarge,
                              AppPadding.xlarge),
                          child: list,
                        ),
                      ),
                    ],
                  );
                }),
      bottomNavigationBar: _loading || _loadError != null
          ? null
          : SafeArea(
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppPadding.xlarge, vertical: AppPadding.medium),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  border: Border(
                      top: BorderSide(
                          color: Theme.of(context).colorScheme.outlineVariant)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _totalLabels == 0
                            ? 'No labels selected'
                            : '$_totalLabels label${_totalLabels == 1 ? '' : 's'} · ${_size.label} · ${_language.label}',
                        style: TextStyle(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant),
                      ),
                    ),
                    const SizedBox(width: 12),
                    AppPrimaryButton(
                      onPressed: _printing || _totalLabels == 0
                          ? null
                          : () => _print(),
                      loading: _printing,
                      icon: const Icon(Icons.print_outlined, size: 18),
                      label: const Text('Print'),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _optionsColumn() {
    final scheme = Theme.of(context).colorScheme;
    final preview = _selectedItems.isNotEmpty ? _selectedItems.first : null;
    final TagLabelItem? tagPreview =
        _selectedTagItems.isNotEmpty ? _selectedTagItems.first : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Printer',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              SegmentedButton<LabelPrinterLanguage>(
                segments: const [
                  ButtonSegment(
                      value: LabelPrinterLanguage.tspl,
                      label: Text('TSC (TSPL)')),
                  ButtonSegment(
                      value: LabelPrinterLanguage.zpl,
                      label: Text('Zebra (ZPL)')),
                ],
                selected: {_language},
                showSelectedIcon: false,
                onSelectionChanged: (selection) async {
                  await _service.setLanguage(selection.first);
                  if (!mounted) return;
                  setState(() => _language = selection.first);
                },
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(Icons.print_outlined,
                      size: 18, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _connection == null || !_connection!.isConfigured
                          ? 'No printer chosen'
                          : _connection!.describe(),
                      style: TextStyle(
                          fontSize: 13, color: scheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: AppSecondaryButton(
                      onPressed: _pickPrinter,
                      icon: const Icon(Icons.settings_outlined, size: 16),
                      label: const Text('Choose'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: AppSecondaryButton(
                      onPressed: _printing ? null : () => _print(test: true),
                      icon: const Icon(Icons.science_outlined, size: 16),
                      label: const Text('Test'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (_isJewellery) ...[
          const SizedBox(height: AppPadding.medium),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('What to print',
                    style:
                        TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('Product labels')),
                    ButtonSegment(value: true, label: Text('Jewellery tags')),
                  ],
                  selected: {_tagMode},
                  showSelectedIcon: false,
                  onSelectionChanged: (selection) =>
                      setState(() => _tagMode = selection.first),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: AppPadding.medium),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Label',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                isExpanded: true,
                value: _customSize ? 'custom' : _size.id,
                decoration: const InputDecoration(labelText: 'Label size'),
                items: [
                  for (final preset in LabelSize.presets)
                    DropdownMenuItem(
                        value: preset.id, child: Text(preset.label)),
                  const DropdownMenuItem(
                      value: 'custom', child: Text('Custom size…')),
                ],
                onChanged: (value) async {
                  if (value == null) return;
                  if (value == 'custom') {
                    if (!mounted) return;
                    setState(() => _customSize = true);
                    return;
                  }
                  await _service.setSize(value);
                  if (!mounted) return;
                  setState(() {
                    _customSize = false;
                    _size = LabelSize.fromId(value);
                  });
                },
              ),
              if (_customSize) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _customWidthController,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        decoration:
                            const InputDecoration(labelText: 'Width (mm)'),
                        onChanged: (_) => _applyCustomSize(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _customHeightController,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        decoration:
                            const InputDecoration(labelText: 'Height (mm)'),
                        onChanged: (_) => _applyCustomSize(),
                      ),
                    ),
                  ],
                ),
              ],
              if (!_tagMode) ...[
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('Product name',
                      style: TextStyle(fontSize: 14)),
                  value: _design.showName,
                  onChanged: (value) =>
                      _updateDesign(_design.copyWith(showName: value)),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('Selling price',
                      style: TextStyle(fontSize: 14)),
                  value: _design.showPrice,
                  onChanged: (value) =>
                      _updateDesign(_design.copyWith(showPrice: value)),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('Code text under bars',
                      style: TextStyle(fontSize: 14)),
                  value: _design.showBarcodeText,
                  onChanged: (value) =>
                      _updateDesign(_design.copyWith(showBarcodeText: value)),
                ),
                const SizedBox(height: 4),
                const Text('Barcode height', style: TextStyle(fontSize: 13)),
                const SizedBox(height: 6),
                SegmentedButton<String>(
                  segments: [
                    for (final height in LabelDesign.barcodeHeights)
                      ButtonSegment(
                          value: height,
                          label: Text(LabelDesign.barcodeHeightLabel(height))),
                  ],
                  selected: {_design.barcodeHeight},
                  showSelectedIcon: false,
                  onSelectionChanged: (selection) => _updateDesign(
                      _design.copyWith(barcodeHeight: selection.first)),
                ),
              ] else ...[
                const SizedBox(height: 4),
                Text(
                  'Tags print name, purity, net weight, price at the '
                  'current rate, and the tag barcode.',
                  style:
                      TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                ),
              ],
            ],
          ),
        ),
        if (!_tagMode && preview != null) ...[
          const SizedBox(height: AppPadding.medium),
          const Text('Preview',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          _LabelPreview(
            name: _design.showName ? preview.product.name : '',
            price: _design.showPrice
                ? '$_currencyCode ${preview.product.price.toStringAsFixed(2)}'
                : '',
            code: preview.code,
            showBarcodeText: _design.showBarcodeText,
            size: _size,
          ),
        ],
        if (_tagMode && tagPreview != null) ...[
          const SizedBox(height: AppPadding.medium),
          const Text('Preview',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          _TagPreview(
            name: tagPreview.product.name,
            detail:
                '${MetalRate.metalLabel(tagPreview.attributes.metal)} ${tagPreview.attributes.purity} · ${tagPreview.netWeight.toStringAsFixed(2)} g',
            price: '$_currencyCode ${tagPreview.price.toStringAsFixed(2)}',
            code: tagPreview.code,
            size: _size,
          ),
        ],
      ],
    );
  }

  Widget _productList() {
    return AppCard(
      padding: const EdgeInsets.all(AppPadding.medium),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          AppSearchField(
            controller: _searchController,
            hintText: 'Search products…',
            onChanged: (value) => setState(() => _query = value),
            onClear: _searchController.text.isEmpty
                ? null
                : () {
                    _searchController.clear();
                    setState(() => _query = '');
                  },
          ),
          const SizedBox(height: 8),
          if (_filtered.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: Text('No products found.')),
            )
          else
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                physics: context.isCompact
                    ? const NeverScrollableScrollPhysics()
                    : const AlwaysScrollableScrollPhysics(),
                itemCount: _filtered.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final product = _filtered[index];
                  final copies = _copies[product.id] ?? 0;
                  final attr = _attributes[product.id];
                  final subtitle = _tagMode
                      ? (attr == null
                          ? 'No weight set — add it in item details'
                          : '${MetalRate.metalLabel(attr.metal)} ${attr.purity} · ${attr.netWeight > 0 ? attr.netWeight : JewelleryCalculator.netWeight(attr.grossWeight, attr.stoneWeight).toStringAsFixed(2)} g net')
                      : (product.barcode.trim().isNotEmpty
                          ? product.barcode
                          : 'No barcode — uses item ID');
                  return Row(
                    children: [
                      Checkbox(
                        value: copies > 0,
                        onChanged: (selected) => setState(() =>
                            _copies[product.id] = selected == true ? 1 : 0),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(product.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600)),
                            Text(
                              subtitle,
                              style: TextStyle(
                                  fontSize: 12,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.remove_circle_outline, size: 20),
                        onPressed: copies > 1
                            ? () =>
                                setState(() => _copies[product.id] = copies - 1)
                            : null,
                      ),
                      Text('$copies',
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                      IconButton(
                        icon: const Icon(Icons.add_circle_outline, size: 20),
                        onPressed: () => setState(() =>
                            _copies[product.id] = (copies + 1).clamp(1, 999)),
                      ),
                    ],
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

/// Approximate on-screen label preview (the printer renders the real
/// barcode from the same name/price/code content).
class _LabelPreview extends StatelessWidget {
  final String name;
  final String price;
  final String code;
  final bool showBarcodeText;
  final LabelSize size;

  const _LabelPreview({
    required this.name,
    required this.price,
    required this.code,
    this.showBarcodeText = true,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AspectRatio(
      aspectRatio: size.widthMm / size.heightMm,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: scheme.surface,
          border: Border.all(color: scheme.outline),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            if (name.isNotEmpty)
              Text(name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w700)),
            if (price.isNotEmpty)
              Text(price, style: const TextStyle(fontSize: 11)),
            Expanded(child: CustomPaint(painter: _BarsPainter(code))),
            if (showBarcodeText)
              Text(code, style: const TextStyle(fontSize: 9, letterSpacing: 1)),
          ],
        ),
      ),
    );
  }
}

/// On-screen jewellery tag preview: same content the TSPL/ZPL tag prints.
class _TagPreview extends StatelessWidget {
  final String name;
  final String detail;
  final String price;
  final String code;
  final LabelSize size;

  const _TagPreview({
    required this.name,
    required this.detail,
    required this.price,
    required this.code,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AspectRatio(
      aspectRatio: size.widthMm / size.heightMm,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: scheme.surface,
          border: Border.all(color: scheme.outline),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            Text(name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
            Text(detail, style: const TextStyle(fontSize: 11)),
            Text(price,
                style:
                    const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
            Expanded(child: CustomPaint(painter: _BarsPainter(code))),
          ],
        ),
      ),
    );
  }
}

class _BarsPainter extends CustomPainter {
  final String code;
  _BarsPainter(this.code);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.black;
    var x = 0.0;
    var i = 0;
    while (x < size.width && i < code.length * 4) {
      final unit = code.codeUnitAt(i % code.length);
      final w = 1.0 + (unit % 3);
      if (i % 2 == 0) {
        canvas.drawRect(Rect.fromLTWH(x, 0, w, size.height), paint);
      }
      x += w + 1;
      i++;
    }
  }

  @override
  bool shouldRepaint(covariant _BarsPainter old) => old.code != code;
}

class _PrinterPickerDialog extends StatefulWidget {
  final LabelPrinterService service;
  final LabelPrinterConnection? initial;

  const _PrinterPickerDialog({required this.service, this.initial});

  @override
  State<_PrinterPickerDialog> createState() => _PrinterPickerDialogState();
}

class _PrinterPickerDialogState extends State<_PrinterPickerDialog> {
  final _ipController = TextEditingController();
  final _portController = TextEditingController(text: '9100');
  bool _scanning = false;
  String? _error;
  List<UsbPrinterInfo> _usb = [];

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    if (initial?.kind == 'network') {
      _ipController.text = initial?.ip ?? '';
      _portController.text = '${initial?.port ?? 9100}';
    }
    _scanUsb();
  }

  @override
  void dispose() {
    _ipController.dispose();
    _portController.dispose();
    super.dispose();
  }

  Future<void> _scanUsb() async {
    setState(() {
      _scanning = true;
      _error = null;
    });
    try {
      final found = await widget.service.discoverUsbPrinters();
      if (!mounted) return;
      setState(() => _usb = found);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  void _choose(LabelPrinterConnection connection) =>
      Navigator.of(context).pop(connection);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Choose label printer'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text('USB printers',
                      style:
                          TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                  const Spacer(),
                  IconButton(
                    icon: _scanning
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.refresh, size: 18),
                    onPressed: _scanning ? null : _scanUsb,
                  ),
                ],
              ),
              if (_error != null)
                Text(_error!,
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.error)),
              if (!_scanning && _usb.isEmpty && _error == null)
                const Text('No USB printers found.',
                    style: TextStyle(fontSize: 13)),
              for (final printer in _usb)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.print_outlined),
                  title: Text(printer.name),
                  subtitle: printer.manufacturer.isNotEmpty
                      ? Text(printer.manufacturer)
                      : null,
                  onTap: () => _choose(LabelPrinterConnection(
                    kind: 'usb',
                    name: printer.name,
                    vendorId: printer.vendorId,
                    productId: printer.productId,
                  )),
                ),
              const Divider(height: 24),
              const Text('Network printer (TCP 9100)',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: TextField(
                      controller: _ipController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Printer IP',
                        hintText: '192.168.1.50',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _portController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Port'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () {
                    final ip = _ipController.text.trim();
                    if (ip.isEmpty) return;
                    _choose(LabelPrinterConnection(
                      kind: 'network',
                      ip: ip,
                      port: int.tryParse(_portController.text.trim()) ?? 9100,
                    ));
                  },
                  icon: const Icon(Icons.check, size: 16),
                  label: const Text('Use this printer'),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
