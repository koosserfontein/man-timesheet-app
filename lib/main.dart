import 'dart:io';
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:signature/signature.dart';
import 'package:path_provider/path_provider.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:flutter/services.dart' show rootBundle;
import 'package:file_picker/file_picker.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();
  await Hive.openBox('timesheet');
  runApp(const ManTimesheetApp());
}

class ManTimesheetApp extends StatelessWidget {
  const ManTimesheetApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'MAN Trucks Timesheet',
        theme: ThemeData(primarySwatch: Colors.indigo),
        home: const HomeScreen(),
        debugShowCheckedModeBanner: false,
      );
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final Box box = Hive.box('timesheet');
  final SignatureController _sigController = SignatureController(
    penStrokeWidth: 5,
    penColor: Colors.black,
    exportBackgroundColor: Colors.white,
  );

  DateTime selectedDate = DateTime.now();

  String technicianName = "Koos Serfontein";
  String selectedBranch = "MAN Nelspruit";

  int? kmStart, kmEnd;
  TimeOfDay arrived = const TimeOfDay(hour: 8, minute: 0);
  TimeOfDay departed = const TimeOfDay(hour: 17, minute: 0);
  String clientName = "Riaan Smit";
  bool isPublicHoliday = false;

  int? editingKey;

  String get currentMonth => DateFormat('yyyy-MM').format(selectedDate);

  final List<String> branches = [
    "MAN Nelspruit",
    "MAN KZN",
    "MAN Bloemfontein",
    "MAN Capetown",
    "MAN Centurion",
  ];

  Future<void> _saveEntry() async {
    if (!isPublicHoliday && _sigController.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("❌ Client must sign (unless Public Holiday)")));
      return;
    }

    final dir = await getApplicationDocumentsDirectory();
    String? sigPath;
    if (!isPublicHoliday) {
      sigPath = '${dir.path}/sig_${DateTime.now().millisecondsSinceEpoch}.png';
      final bytes = await _sigController.toPngBytes();
      if (bytes != null) await File(sigPath).writeAsBytes(bytes);
    }

    final data = {
      'date': selectedDate.toIso8601String(),
      'month': currentMonth,
      'technician': technicianName,
      'clientCompany': selectedBranch,
      'kmStart': kmStart,
      'kmEnd': kmEnd,
      'arrived': arrived.format(context),
      'departed': departed.format(context),
      'client': clientName,
      'isHoliday': isPublicHoliday,
      'signature': sigPath ?? '',
    };

    if (editingKey != null) {
      await box.put(editingKey, data);
      editingKey = null;
    } else {
      await box.add(data);
    }

    _sigController.clear();
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(editingKey == null ? "✅ Entry Saved" : "✅ Entry Updated")),
    );
  }

  List getEntriesForCurrentMonth() {
    final all = box.values.toList();
    return all.where((e) => (e['month'] ?? '') == currentMonth).toList()
      ..sort((a, b) => DateTime.parse(a['date']).compareTo(DateTime.parse(b['date'])));
  }

  List getEntriesForMonth(String month) {
    final all = box.values.toList();
    return all.where((e) => (e['month'] ?? '') == month).toList()
      ..sort((a, b) => DateTime.parse(a['date']).compareTo(DateTime.parse(b['date'])));
  }

  void _editEntry(int key, Map entry) {
    setState(() {
      selectedDate = DateTime.parse(entry['date']);
      technicianName = entry['technician'] ?? "Koos Serfontein";
      
      // Handle old "MAN TRUCKS" values
      String savedBranch = entry['clientCompany'] ?? "MAN Nelspruit";
      if (branches.contains(savedBranch)) {
        selectedBranch = savedBranch;
      } else {
        selectedBranch = "MAN Nelspruit"; // fallback
      }

      kmStart = entry['kmStart'];
      kmEnd = entry['kmEnd'];
      arrived = TimeOfDay.fromDateTime(DateTime.parse("2000-01-01 ${entry['arrived'] ?? '08:00'}"));
      departed = TimeOfDay.fromDateTime(DateTime.parse("2000-01-01 ${entry['departed'] ?? '17:00'}"));
      clientName = entry['client'] ?? "Riaan Smit";
      isPublicHoliday = entry['isHoliday'] ?? false;
      editingKey = key;
    });
  }

  Future<void> _deleteEntry(int key) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Delete Entry?"),
        content: const Text("This action cannot be undone."),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text("Cancel")),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text("Delete", style: TextStyle(color: Colors.red))),
        ],
      ),
    );

    if (confirm == true) {
      await box.delete(key);
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("✅ Entry Deleted")));
    }
  }

  Future<void> _resetAllData() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("⚠️ Reset All Data?"),
        content: const Text("This will permanently delete ALL entries.\n\nThis cannot be undone!"),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text("Cancel")),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text("Yes, Reset All", style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold))),
        ],
      ),
    );

    if (confirm == true) {
      await box.clear();
      setState(() {});
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("✅ All data has been reset"), backgroundColor: Colors.red));
    }
  }

  Future<void> _exportToCsv() async {
    final entries = box.values.toList()..sort((a, b) => DateTime.parse(a['date']).compareTo(DateTime.parse(b['date'])));
    if (entries.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("No data to backup")));
      return;
    }

    final StringBuffer csv = StringBuffer();
    csv.writeln("Date,Month,KM Start,KM End,Time Arrived,Time Departed,Client Name,Technician,Client Company,Is Holiday");

    for (var e in entries) {
      final date = DateFormat('yyyy-MM-dd').format(DateTime.parse(e['date']));
      csv.writeln('"$date","${e['month'] ?? ''}",${e['kmStart'] ?? ''},${e['kmEnd'] ?? ''},"${e['arrived'] ?? ''}","${e['departed'] ?? ''}","${e['client'] ?? ''}","${e['technician'] ?? ''}","${e['clientCompany'] ?? ''}",${e['isHoliday'] ?? false}');
    }

    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/MAN_Timesheet_Full_Backup.csv');
    await file.writeAsString(csv.toString());

    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("✅ Full Backup Created"), backgroundColor: Colors.green));
    await Share.shareXFiles([XFile(file.path)]);
    Navigator.pop(context);
  }

  Future<void> _importCsv() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['csv']);
    if (result == null) return;

    final file = File(result.files.single.path!);
    final content = await file.readAsString();
    final lines = content.split('\n');

    int imported = 0;
    for (var line in lines.skip(1)) {
      if (line.trim().isEmpty) continue;
      final values = line.split(',');
      if (values.length >= 9) {
        try {
          final date = DateTime.parse(values[0].replaceAll('"', ''));
          await box.add({
            'date': date.toIso8601String(),
            'month': values[1].replaceAll('"', ''),
            'technician': values[7].replaceAll('"', ''),
            'clientCompany': values[8].replaceAll('"', ''),
            'kmStart': int.tryParse(values[2]),
            'kmEnd': int.tryParse(values[3]),
            'arrived': values[4].replaceAll('"', ''),
            'departed': values[5].replaceAll('"', ''),
            'client': values[6].replaceAll('"', ''),
            'isHoliday': values[9].trim().toLowerCase() == 'true',
            'signature': '',
          });
          imported++;
        } catch (_) {}
      }
    }

    setState(() {});
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("✅ Restored $imported entries"), backgroundColor: Colors.green));
  }

  Future<void> _generatePdf() async {
    final entries = getEntriesForCurrentMonth();
    if (entries.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("No entries for this month")));
      return;
    }

    final manLogo = await rootBundle.load('assets/man_logo.png');
    final co8Logo = await rootBundle.load('assets/co8_logo.png');

    final pdf = pw.Document();

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.all(40),
        build: (pw.Context context) => [
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Image(pw.MemoryImage(manLogo.buffer.asUint8List()), height: 95),
              pw.Column(
                children: [
                  pw.Text('CLIENT : $selectedBranch'),
                  pw.Text('MONTH : ${DateFormat('MMMM yyyy').format(selectedDate)}'),
                  pw.Text('TECHNICIAN : $technicianName'),
                ],
              ),
              pw.Image(pw.MemoryImage(co8Logo.buffer.asUint8List()), height: 95),
            ],
          ),
          pw.Divider(height: 30, thickness: 2),

          pw.Table(
            border: pw.TableBorder.all(width: 1.5),
            columnWidths: {
              0: const pw.FlexColumnWidth(1.2),
              1: const pw.FlexColumnWidth(1),
              2: const pw.FlexColumnWidth(1),
              3: const pw.FlexColumnWidth(1),
              4: const pw.FlexColumnWidth(1),
              5: const pw.FlexColumnWidth(1.4),
              6: const pw.FlexColumnWidth(2.2),
            },
            children: [
              pw.TableRow(
                decoration: const pw.BoxDecoration(color: PdfColors.grey300),
                children: [
                  pw.Padding(padding: const pw.EdgeInsets.all(8), child: pw.Text('DATE', style: pw.TextStyle(fontWeight: pw.FontWeight.bold))),
                  pw.Padding(padding: const pw.EdgeInsets.all(8), child: pw.Text('KM START', style: pw.TextStyle(fontWeight: pw.FontWeight.bold))),
                  pw.Padding(padding: const pw.EdgeInsets.all(8), child: pw.Text('KM END', style: pw.TextStyle(fontWeight: pw.FontWeight.bold))),
                  pw.Padding(padding: const pw.EdgeInsets.all(8), child: pw.Text('TIME ARRIVED', style: pw.TextStyle(fontWeight: pw.FontWeight.bold))),
                  pw.Padding(padding: const pw.EdgeInsets.all(8), child: pw.Text('TIME DEPARTED', style: pw.TextStyle(fontWeight: pw.FontWeight.bold))),
                  pw.Padding(padding: const pw.EdgeInsets.all(8), child: pw.Text('CLIENT NAME', style: pw.TextStyle(fontWeight: pw.FontWeight.bold))),
                  pw.Padding(padding: const pw.EdgeInsets.all(8), child: pw.Text('CLIENT SIGNATURE', style: pw.TextStyle(fontWeight: pw.FontWeight.bold))),
                ],
              ),
              ...entries.map((e) {
                final isHoliday = e['isHoliday'] ?? false;
                final sigFile = File(e['signature'] ?? '');
                return pw.TableRow(
                  children: [
                    pw.Padding(
                      padding: const pw.EdgeInsets.all(8),
                      child: isHoliday 
                          ? pw.Text('PUBLIC HOLIDAY', style: pw.TextStyle(color: PdfColors.orange, fontWeight: pw.FontWeight.bold))
                          : pw.Text(DateFormat('yyyy/MM/dd').format(DateTime.parse(e['date']))),
                    ),
                    pw.Padding(padding: const pw.EdgeInsets.all(8), child: pw.Text(isHoliday ? '-' : (e['kmStart']?.toString() ?? '-'))),
                    pw.Padding(padding: const pw.EdgeInsets.all(8), child: pw.Text(isHoliday ? '-' : (e['kmEnd']?.toString() ?? '-'))),
                    pw.Padding(padding: const pw.EdgeInsets.all(8), child: pw.Text(isHoliday ? '-' : (e['arrived'] ?? '-'))),
                    pw.Padding(padding: const pw.EdgeInsets.all(8), child: pw.Text(isHoliday ? '-' : (e['departed'] ?? '-'))),
                    pw.Padding(padding: const pw.EdgeInsets.all(8), child: pw.Text(isHoliday ? 'HOLIDAY' : (e['client'] ?? '-'))),
                    pw.Padding(
                      padding: const pw.EdgeInsets.all(4),
                      child: isHoliday 
                          ? pw.Text('HOLIDAY', style: pw.TextStyle(color: PdfColors.orange, fontWeight: pw.FontWeight.bold))
                          : (sigFile.existsSync()
                              ? pw.Image(pw.MemoryImage(sigFile.readAsBytesSync()), height: 55)
                              : pw.Text('[Signature]', style: const pw.TextStyle(color: PdfColors.grey))),
                    ),
                  ],
                );
              }).toList(),
            ],
          ),
          pw.SizedBox(height: 20),
          pw.Text('Total Entries: ${entries.length}', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
        ],
      ),
    );

    final dir = await getApplicationDocumentsDirectory();
    final outputFile = File('${dir.path}/MAN_Timesheet_${currentMonth}.pdf');
    await outputFile.writeAsBytes(await pdf.save());

    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("✅ PDF Created!"), backgroundColor: Colors.green));
    await Share.shareXFiles([XFile(outputFile.path)]);
  }

  void _showSettings() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text("Settings", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 20),
            ListTile(
              leading: const Icon(Icons.history, color: Colors.purple),
              title: const Text("View History"),
              onTap: () {
                Navigator.pop(context);
                _showHistory();
              },
            ),
            ListTile(
              leading: const Icon(Icons.backup, color: Colors.green),
              title: const Text("Backup Data (Export CSV)"),
              onTap: _exportToCsv,
            ),
            ListTile(
              leading: const Icon(Icons.restore, color: Colors.blue),
              title: const Text("Restore Data (Import CSV)"),
              onTap: _importCsv,
            ),
            ListTile(
              leading: const Icon(Icons.delete_forever, color: Colors.red),
              title: const Text("Reset All Data"),
              onTap: _resetAllData,
            ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
  }

  void _showHistory() {
    String viewMonth = currentMonth;
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final entries = getEntriesForMonth(viewMonth);
          return AlertDialog(
            title: const Text("History"),
            content: SizedBox(
              width: double.maxFinite,
              height: 500,
              child: Column(
                children: [
                  DropdownButton<String>(
                    value: viewMonth,
                    isExpanded: true,
                    items: List.generate(24, (i) {
                      final date = DateTime(2025 + (i ~/ 12), (i % 12) + 1);
                      final m = DateFormat('yyyy-MM').format(date);
                      return DropdownMenuItem(value: m, child: Text(DateFormat('MMMM yyyy').format(date)));
                    }),
                    onChanged: (v) => v != null ? setDialogState(() => viewMonth = v) : null,
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: entries.isEmpty
                        ? const Center(child: Text("No entries for this month"))
                        : ListView.builder(
                            itemCount: entries.length,
                            itemBuilder: (_, i) {
                              final key = box.keyAt(box.values.toList().indexOf(entries[i]));
                              final e = entries[i];
                              final isHoliday = e['isHoliday'] ?? false;
                              return ListTile(
                                title: Text(DateFormat('dd MMM yyyy').format(DateTime.parse(e['date']))),
                                subtitle: Text(isHoliday ? "🟠 PUBLIC HOLIDAY" : "${e['arrived']} - ${e['departed']} | ${e['client']}"),
                                onLongPress: () {
                                  Navigator.pop(context);
                                  _editEntry(key, e);
                                },
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
            actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text("Close"))],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final currentEntries = getEntriesForCurrentMonth();

    return Scaffold(
      appBar: AppBar(
        title: const Text("MAN Trucks Timesheet"),
        actions: [
          IconButton(icon: const Icon(Icons.download), onPressed: _generatePdf),
          IconButton(icon: const Icon(Icons.settings), onPressed: _showSettings),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Card(
              child: ListTile(
                leading: const Icon(Icons.calendar_today, size: 32, color: Colors.indigo),
                title: const Text("Entry Date", style: TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Text(DateFormat('EEEE, dd MMMM yyyy').format(selectedDate), style: const TextStyle(fontSize: 17)),
                onTap: () async {
                  final d = await showDatePicker(
                    context: context,
                    initialDate: selectedDate,
                    firstDate: DateTime(2025),
                    lastDate: DateTime(2027),
                  );
                  if (d != null) setState(() => selectedDate = d);
                },
              ),
            ),
            const SizedBox(height: 8),

            SwitchListTile(
              title: const Text("Public Holiday (No work)"),
              value: isPublicHoliday,
              onChanged: (val) => setState(() => isPublicHoliday = val),
              activeColor: Colors.orange,
            ),
            const SizedBox(height: 12),

            TextField(
              decoration: const InputDecoration(labelText: "Technician Name", border: OutlineInputBorder()),
              controller: TextEditingController(text: technicianName),
              onChanged: (v) => technicianName = v,
            ),
            const SizedBox(height: 12),

            DropdownButtonFormField<String>(
              decoration: const InputDecoration(
                labelText: "MAN Branch",
                border: OutlineInputBorder(),
              ),
              value: branches.contains(selectedBranch) ? selectedBranch : branches.first,
              items: branches.map((branch) => DropdownMenuItem(value: branch, child: Text(branch))).toList(),
              onChanged: (value) {
                if (value != null) setState(() => selectedBranch = value);
              },
            ),
            const SizedBox(height: 20),

            if (!isPublicHoliday) ...[
              Row(children: [
                Expanded(child: TextField(decoration: const InputDecoration(labelText: "KM Start", border: OutlineInputBorder()), keyboardType: TextInputType.number, onChanged: (v) => kmStart = int.tryParse(v))),
                const SizedBox(width: 12),
                Expanded(child: TextField(decoration: const InputDecoration(labelText: "KM End", border: OutlineInputBorder()), keyboardType: TextInputType.number, onChanged: (v) => kmEnd = int.tryParse(v))),
              ]),
              const SizedBox(height: 12),

              Row(children: [
                Expanded(child: ListTile(title: const Text("Time Arrived"), subtitle: Text(arrived.format(context)), onTap: () async {
                  final t = await showTimePicker(context: context, initialTime: arrived);
                  if (t != null) setState(() => arrived = t);
                })),
                Expanded(child: ListTile(title: const Text("Time Departed"), subtitle: Text(departed.format(context)), onTap: () async {
                  final t = await showTimePicker(context: context, initialTime: departed);
                  if (t != null) setState(() => departed = t);
                })),
              ]),
              const SizedBox(height: 12),

              TextField(
                decoration: const InputDecoration(labelText: "Client Name", border: OutlineInputBorder()),
                controller: TextEditingController(text: clientName),
                onChanged: (v) => clientName = v,
              ),
              const SizedBox(height: 24),

              const Text("Client Signature", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              Container(
                height: 240,
                decoration: BoxDecoration(border: Border.all(color: Colors.grey, width: 2), borderRadius: BorderRadius.circular(8)),
                child: Signature(controller: _sigController, backgroundColor: Colors.white),
              ),
            ],

            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              TextButton(onPressed: _sigController.clear, child: const Text("Clear Signature")),
              ElevatedButton(onPressed: _saveEntry, child: Text(editingKey == null ? "Save Entry" : "Update Entry")),
            ]),

            const Divider(height: 40),
            Text("Saved Entries for ${DateFormat('MMMM yyyy').format(selectedDate)}", style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            SizedBox(
              height: 300,
              child: ListView.builder(
                itemCount: currentEntries.length,
                itemBuilder: (_, i) {
                  final key = box.keyAt(box.values.toList().indexOf(currentEntries[i]));
                  final e = currentEntries[i];
                  final isHoliday = e['isHoliday'] ?? false;
                  return ListTile(
                    title: Text(DateFormat('dd MMM yyyy').format(DateTime.parse(e['date']))),
                    subtitle: Text(isHoliday ? "🟠 PUBLIC HOLIDAY" : "${e['arrived']} - ${e['departed']} | ${e['client']}"),
                    tileColor: isHoliday ? Colors.orange.withOpacity(0.1) : null,
                    onLongPress: () {
                      showModalBottomSheet(
                        context: context,
                        builder: (context) => Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ListTile(leading: const Icon(Icons.edit), title: const Text("Edit Entry"), onTap: () { Navigator.pop(context); _editEntry(key, e); }),
                            ListTile(leading: const Icon(Icons.delete, color: Colors.red), title: const Text("Delete Entry", style: TextStyle(color: Colors.red)), onTap: () { Navigator.pop(context); _deleteEntry(key); }),
                          ],
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
                   