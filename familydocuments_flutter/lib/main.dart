import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'core/auth/auth_service.dart';
import 'core/home/home_intent.dart';
import 'core/home/home_service.dart';
import 'core/home/reminder_parser.dart';

void main() => runApp(const FamilyDocumentsApp());

class SelectedUpload {
  const SelectedUpload({required this.name, required this.bytes});
  final String name;
  final Uint8List bytes;
}

class FamilyDocumentsApp extends StatefulWidget {
  const FamilyDocumentsApp({
    super.key,
    this.auth,
    this.homeService,
    this.pickUpload,
  });
  final AuthService? auth;
  final HomeService? homeService;
  final Future<SelectedUpload?> Function()? pickUpload;
  @override
  State<FamilyDocumentsApp> createState() => _AppState();
}

class _AppState extends State<FamilyDocumentsApp> {
  final navigatorKey = GlobalKey<NavigatorState>();
  late final AuthService auth;
  late final HomeService homeService;
  bool checking = true, signingIn = false, busy = false;
  String? error, message, retryAction;
  SearchResponse? searchResponse;
  OrganisedDocument? organisedDocument;
  String? suggestedDestination;
  String? unresolvedCategory;
  bool categoryMatchAmbiguous = false;
  String? uploadedName, uploadedMimeType;
  Uint8List? uploadedBytes;
  final Map<String, AnalysisJob> analysisJobs = {};
  Timer? analysisTimer;
  String? analysisRequestId;
  String? reminderRequestId, reminderInstruction;
  int analysisPolls = 0;
  int tab = 0;
  final query = TextEditingController();
  @override
  void initState() {
    super.initState();
    auth = widget.auth ?? AuthService();
    homeService = widget.homeService ?? HomeService(auth);
    _restore();
  }

  Future<void> _restore() async {
    try {
      await auth.restore();
    } catch (_) {}
    if (auth.session != null) await _restoreAnalysisJobs();
    if (mounted) setState(() => checking = false);
  }

  Future<void> signIn(String e, String p) async {
    setState(() => signingIn = true);
    try {
      await auth.signIn(e, p);
      await _restoreAnalysisJobs();
      if (mounted) setState(() => error = null);
    } on AuthException catch (x) {
      if (mounted) setState(() => error = x.message);
    } finally {
      if (mounted) setState(() => signingIn = false);
    }
  }

  Future<void> send() async {
    if (busy) return;
    if (uploadedBytes != null) return _sendAttachment();
    final instruction = query.text.trim();
    switch (parseHomeIntent(instruction, hasAttachment: false).type) {
      case HomeIntentType.search:
        return search();
      case HomeIntentType.reminder:
        return _createReminder(instruction);
      case HomeIntentType.viewCategory:
        setState(() {
          message =
              'Would you like to add a document, save a link, or view your $instruction items?';
          error = null;
        });
        return;
      default:
        setState(() {
          message = 'What would you like to add? You can attach a document, save a link, or create a reminder.';
          error = null;
        });
        return;
    }
  }

  Future<void> _createReminder(String instruction) async {
    ParsedReminder parsed;
    try {
      parsed = parseReminderCommand(instruction);
    } on ReminderClarification catch (clarification) {
      setState(() {
        message = clarification.message;
        error = null;
      });
      return;
    }
    setState(() {
      busy = true;
      error = null;
      message = 'Adding your reminder…';
      retryAction = 'reminder';
    });
    if (reminderInstruction != instruction) {
      reminderInstruction = instruction;
      reminderRequestId =
          'home-${auth.session?.userId ?? 'user'}-${DateTime.now().microsecondsSinceEpoch}';
    }
    try {
      final result = await homeService.createReminder(
        title: parsed.title,
        dueDate: parsed.dueDate,
        dueTime: parsed.dueTime,
        requestId: reminderRequestId!,
      );
      if (mounted) {
        setState(() {
          message = 'Reminder added: ${result.title} — ${parsed.displayWhen}';
          retryAction = null;
          reminderRequestId = null;
          reminderInstruction = null;
          query.clear();
        });
      }
    } on HomeServiceException catch (failure) {
      if (mounted) setState(() => error = failure.message);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> search() async {
    if (query.text.trim().isEmpty) return;
    final submitted = query.text.trim();
    setState(() {
      busy = true;
      error = null;
      retryAction = 'search';
      message = null;
      searchResponse = null;
      organisedDocument = null;
    });
    try {
      final result = await homeService.search(submitted);
      if (mounted) {
        setState(() => searchResponse = result);
      }
    } on AuthException catch (x) {
      await auth.clear();
      if (mounted) {
        setState(() => error = x.message);
      }
    } on HomeServiceException catch (x) {
      if (mounted) {
        setState(() => error = x.message);
      }
    } catch (_) {
      if (mounted) {
        setState(() => error = 'Search could not be reached. Try again.');
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  Future<void> upload() async {
    final selected = widget.pickUpload != null
        ? await widget.pickUpload!()
        : await _pickFile();
    if (selected == null) return;
    setState(() {
      error = null;
      uploadedName = selected.name;
      uploadedMimeType = _mimeType(selected.name);
      uploadedBytes = selected.bytes;
      message = null;
      analysisRequestId = null;
    });
  }

  Future<SelectedUpload?> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      withData: true,
      type: FileType.custom,
      allowedExtensions: ['pdf', 'jpg', 'jpeg', 'png'],
    );
    if (result == null || result.files.single.bytes == null) return null;
    final file = result.files.single;
    return SelectedUpload(name: file.name, bytes: file.bytes!);
  }

  Future<void> _sendAttachment() async {
    final instruction = query.text.trim();
    final intent = parseHomeIntent(instruction, hasAttachment: true);
    final name = uploadedName!;
    if (intent.type == HomeIntentType.vagueAttachment) {
      final hint = metadataCategoryHint(name);
      if (hint != null) {
        setState(() {
          message = 'This looks like it belongs in $hint. Save it there?';
          suggestedDestination = hint;
          error = null;
        });
        return;
      }
    }
    final needsAnalysis =
        intent.type == HomeIntentType.readAttachment ||
        intent.type == HomeIntentType.invoiceAttachment ||
        intent.type == HomeIntentType.vagueAttachment;
    final category = intent.destination;
    if (!needsAnalysis && category == null) {
      setState(
        () => error = 'Tell me where to save it, for example “Add to Rental 1”, or ask me to read it as a bill.',
      );
      return;
    }
    final bytes = uploadedBytes!;
    final mimeType = uploadedMimeType!;
    setState(() {
      busy = true;
      error = null;
      retryAction = 'upload';
      message = needsAnalysis
          ? 'Reading and organising your document…'
          : 'Saving to $category…';
      searchResponse = null;
      organisedDocument = null;
      suggestedDestination = null;
      unresolvedCategory = null;
      categoryMatchAmbiguous = false;
    });
    try {
      if (needsAnalysis) {
        analysisRequestId ??=
            'ocr-${auth.session?.userId ?? 'user'}-${DateTime.now().microsecondsSinceEpoch}';
        final job = await homeService.submitAnalysisJob(
          name: name,
          mimeType: mimeType,
          bytes: bytes,
          invoice: intent.type == HomeIntentType.invoiceAttachment,
          idempotencyKey: analysisRequestId!,
        );
        if (mounted) {
          setState(() {
            analysisJobs[job.id] = job;
            message =
                'Uploaded. Reading and organising $name in the background…';
            uploadedBytes = null;
            uploadedName = null;
            uploadedMimeType = null;
            analysisRequestId = null;
            query.clear();
          });
          _startAnalysisPolling();
        }
        return;
      }
      final resolution = await homeService.resolveCategory(category!);
      if (!mounted) return;
      if (resolution.type != CategoryResolutionType.found) {
        final canonical = canonicalCategoryName(category);
        setState(() {
          unresolvedCategory = category;
          categoryMatchAmbiguous =
              resolution.type == CategoryResolutionType.ambiguous;
          retryAction = null;
          message = categoryMatchAmbiguous
              ? 'I found more than one matching category. Which one should I use?'
              : 'Your family doesn’t have a $canonical category yet. Would you like to create it?';
        });
        return;
      }
      final result = await homeService.saveUpload(
        name: name,
        mimeType: mimeType,
        bytes: bytes,
        category: resolution.category!,
      );
      if (mounted) {
        setState(() {
          message = 'Saved in ${result.category}.';
          organisedDocument = result;
          uploadedBytes = null;
          uploadedName = null;
          uploadedMimeType = null;
          retryAction = null;
          query.clear();
        });
      }
    } on AuthException catch (x) {
      await auth.clear();
      if (mounted) {
        setState(() => error = x.message);
      }
    } on HomeServiceException catch (x) {
      if (mounted) {
        setState(() => error = x.message);
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => error = 'Your document could not be processed. Try again.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  Future<void> _restoreAnalysisJobs() async {
    try {
      final jobs = await homeService.pendingAnalysisJobs();
      if (!mounted || jobs.isEmpty) return;
      setState(() {
        for (final job in jobs) {
          analysisJobs[job.id] = job;
        }
        final completed = jobs
            .where((job) => job.status == 'succeeded' && job.result != null)
            .lastOrNull;
        final failed = jobs
            .where(
              (job) =>
                  job.status == 'failed' || job.status == 'permanent_failed',
            )
            .lastOrNull;
        if (completed != null) {
          organisedDocument = completed.result;
          message = null;
        } else if (failed != null) {
          error = 'I couldn’t read this document.';
          retryAction = failed.retryAllowed ? 'analysis:${failed.id}' : null;
        } else {
          message = 'Resuming document processing…';
        }
      });
      _startAnalysisPolling();
    } catch (_) {}
  }

  void _startAnalysisPolling() {
    if (analysisTimer?.isActive ?? false) return;
    analysisPolls = 0;
    analysisTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _pollAnalysisJobs(),
    );
    _pollAnalysisJobs();
  }

  Future<void> _pollAnalysisJobs() async {
    if (!mounted || auth.session == null) {
      _stopAnalysisPolling();
      return;
    }
    final active = analysisJobs.values.where((job) => !job.terminal).toList();
    if (active.isEmpty) {
      _stopAnalysisPolling();
      return;
    }
    if (++analysisPolls > 120) {
      _stopAnalysisPolling();
      if (mounted) {
        setState(
          () => message = 'Processing is still continuing. Return to Home to refresh its status.',
        );
      }
      return;
    }
    for (final current in active) {
      try {
        final job = await homeService.analysisJob(current.id);
        if (!mounted) return;
        setState(() {
          analysisJobs[job.id] = job;
          if (job.status == 'succeeded' && job.result != null) {
            organisedDocument = job.result;
            message = null;
          } else if (job.status == 'failed' ||
              job.status == 'permanent_failed') {
            error = 'I couldn’t read this document.';
            retryAction = job.retryAllowed ? 'analysis:${job.id}' : null;
          } else {
            message = job.status == 'queued'
                ? 'Your document is queued for reading…'
                : 'Reading and organising your document in the background…';
          }
        });
      } on AuthException {
        await auth.clear();
        _stopAnalysisPolling();
      } catch (_) {
        // A transient status failure does not cancel durable server processing.
      }
    }
  }

  void _stopAnalysisPolling() {
    analysisTimer?.cancel();
    analysisTimer = null;
  }

  Future<void> retry() async {
    if (retryAction == 'search') return search();
    if (retryAction == 'upload') return _sendAttachment();
    if (retryAction == 'reminder' && reminderInstruction != null) {
      return _createReminder(reminderInstruction!);
    }
    if (retryAction?.startsWith('analysis:') ?? false) {
      final id = retryAction!.substring('analysis:'.length);
      final job = await homeService.retryAnalysisJob(id);
      if (mounted) {
        setState(() {
          analysisJobs[id] = job;
          error = null;
          message = 'Trying to read your document again…';
          retryAction = null;
        });
      }
      _startAnalysisPolling();
    }
  }

  void clearAttachment() => setState(() {
    uploadedBytes = null;
    uploadedName = null;
    uploadedMimeType = null;
    analysisRequestId = null;
    unresolvedCategory = null;
    categoryMatchAmbiguous = false;
  });

  Future<void> saveSuggestion() async {
    if (suggestedDestination == null) return;
    query.text = 'Save this in $suggestedDestination';
    await _sendAttachment();
  }

  Future<void> createAndSaveCategory() async {
    final requested = unresolvedCategory;
    if (requested == null || uploadedBytes == null || busy) return;
    setState(() {
      busy = true;
      error = null;
      message = 'Creating your category…';
    });
    try {
      final category = await homeService.createCategory(requested);
      await _saveCurrentAttachmentIn(category);
    } on AuthException catch (failure) {
      await auth.clear();
      if (mounted) setState(() => error = failure.message);
    } on HomeServiceException catch (failure) {
      if (mounted) setState(() => error = failure.message);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> chooseUploadCategory() async {
    if (uploadedBytes == null || busy) return;
    try {
      final categories = await homeService.categories();
      if (!mounted) return;
      final chosen = await showDialog<String>(
        context: navigatorKey.currentContext!,
        builder: (dialogContext) => SimpleDialog(
          title: const Text('Choose category'),
          children: categories
              .map(
                (category) => SimpleDialogOption(
                  onPressed: () => Navigator.pop(dialogContext, category),
                  child: Text(category),
                ),
              )
              .toList(),
        ),
      );
      if (chosen == null) return;
      if (mounted) setState(() => busy = true);
      await _saveCurrentAttachmentIn(chosen);
    } on AuthException catch (failure) {
      await auth.clear();
      if (mounted) setState(() => error = failure.message);
    } on HomeServiceException catch (failure) {
      if (mounted) setState(() => error = failure.message);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _saveCurrentAttachmentIn(String category) async {
    final bytes = uploadedBytes;
    final name = uploadedName;
    final mimeType = uploadedMimeType;
    if (bytes == null || name == null || mimeType == null) return;
    if (mounted) {
      setState(() {
        error = null;
        message = 'Saving to $category…';
      });
    }
    final result = await homeService.saveUpload(
      name: name,
      mimeType: mimeType,
      bytes: bytes,
      category: category,
    );
    if (!mounted) return;
    setState(() {
      message = 'Saved in ${result.category}.';
      organisedDocument = result;
      uploadedBytes = null;
      uploadedName = null;
      uploadedMimeType = null;
      unresolvedCategory = null;
      categoryMatchAmbiguous = false;
      retryAction = null;
      query.clear();
    });
  }

  void cancelCategoryChoice() => setState(() {
    unresolvedCategory = null;
    categoryMatchAmbiguous = false;
    error = null;
    message = 'Not saved. Your document is still attached.';
  });

  Future<void> saveFailedAnalysisWithoutReading() async {
    final retry = retryAction;
    if (retry == null || !retry.startsWith('analysis:')) return;
    try {
      await homeService.dismissAnalysisJob(retry.substring('analysis:'.length));
      if (mounted) {
        setState(() {
          analysisJobs.remove(retry.substring('analysis:'.length));
          error = null;
          retryAction = null;
          message = 'Saved without reading. You can change its category later.';
        });
      }
    } on HomeServiceException catch (failure) {
      if (mounted) setState(() => error = failure.message);
    }
  }

  Future<void> chooseFailedAnalysisCategory() async {
    final retry = retryAction;
    if (retry == null || !retry.startsWith('analysis:')) return;
    try {
      final categories = await homeService.categories();
      if (!mounted) return;
      final chosen = await showDialog<String>(
        context: navigatorKey.currentContext!,
        builder: (dialogContext) => SimpleDialog(
          title: const Text('Choose category'),
          children: categories
              .map(
                (category) => SimpleDialogOption(
                  onPressed: () => Navigator.pop(dialogContext, category),
                  child: Text(category),
                ),
              )
              .toList(),
        ),
      );
      if (chosen == null) return;
      await homeService.categorizeAnalysisJob(
        retry.substring('analysis:'.length),
        chosen,
      );
      if (mounted) {
        setState(() {
          analysisJobs.remove(retry.substring('analysis:'.length));
          error = null;
          retryAction = null;
          message = 'Saved in $chosen without reading.';
        });
      }
    } on HomeServiceException catch (failure) {
      if (mounted) setState(() => error = failure.message);
    }
  }

  Future<void> dismissFailedAnalysis() async {
    final retry = retryAction;
    if (retry == null || !retry.startsWith('analysis:')) return;
    final id = retry.substring('analysis:'.length);
    try {
      await homeService.dismissAnalysisJob(id);
      if (mounted) {
        setState(() {
          analysisJobs.remove(id);
          error = null;
          retryAction = null;
          message = null;
        });
      }
    } on HomeServiceException catch (failure) {
      if (mounted) setState(() => error = failure.message);
    }
  }

  static String _mimeType(String name) {
    final extension = name.split('.').last.toLowerCase();
    return switch (extension) {
      'pdf' => 'application/pdf',
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      _ => 'application/octet-stream',
    };
  }

  Future<void> signOut() async {
    _stopAnalysisPolling();
    analysisJobs.clear();
    analysisRequestId = null;
    reminderRequestId = null;
    reminderInstruction = null;
    unresolvedCategory = null;
    categoryMatchAmbiguous = false;
    setState(() => checking = true);
    await auth.signOut();
    if (mounted) setState(() => checking = false);
  }

  @override
  void dispose() {
    _stopAnalysisPolling();
    query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext c) => MaterialApp(
    navigatorKey: navigatorKey,
    title: 'FamilyDocuments',
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff245b52)),
    ),
    home: checking
        ? const Scaffold(body: Center(child: Text('Checking your session…')))
        : auth.session == null
        ? Login(onSubmit: signIn, busy: signingIn, error: error)
        : Shell(
            tab: tab,
            onTab: (v) => setState(() => tab = v),
            query: query,
            busy: busy,
            message: message,
            error: error,
            searchResponse: searchResponse,
            organisedDocument: organisedDocument,
            suggestedDestination: suggestedDestination,
            unresolvedCategory: unresolvedCategory,
            categoryMatchAmbiguous: categoryMatchAmbiguous,
            uploadedName: uploadedName,
            onSend: send,
            onUpload: upload,
            onClearAttachment: clearAttachment,
            onSaveSuggestion: saveSuggestion,
            onCreateAndSaveCategory: createAndSaveCategory,
            onChooseUploadCategory: chooseUploadCategory,
            onCancelCategoryChoice: cancelCategoryChoice,
            onRetry: retry,
            analysisFailure: retryAction?.startsWith('analysis:') ?? false,
            onSaveWithoutReading: saveFailedAnalysisWithoutReading,
            onChooseCategory: chooseFailedAnalysisCategory,
            onDismissAnalysis: dismissFailedAnalysis,
            email: auth.session!.email,
            onSignOut: signOut,
          ),
  );
}

class Login extends StatefulWidget {
  const Login({
    super.key,
    required this.onSubmit,
    required this.busy,
    this.error,
  });
  final Future<void> Function(String, String) onSubmit;
  final bool busy;
  final String? error;
  @override
  State<Login> createState() => _LoginState();
}

class _LoginState extends State<Login> {
  final email = TextEditingController(), password = TextEditingController();
  @override
  Widget build(BuildContext c) => Scaffold(
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'FamilyDocuments',
                style: Theme.of(c).textTheme.headlineMedium,
              ),
              TextField(
                controller: email,
                decoration: const InputDecoration(labelText: 'Email'),
              ),
              TextField(
                controller: password,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Password'),
              ),
              if (widget.error != null)
                Text(widget.error!, style: const TextStyle(color: Colors.red)),
              FilledButton(
                onPressed: widget.busy
                    ? null
                    : () => widget.onSubmit(email.text, password.text),
                child: Text(widget.busy ? 'Signing in…' : 'Sign in'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class Shell extends StatelessWidget {
  const Shell({
    super.key,
    required this.tab,
    required this.onTab,
    required this.query,
    required this.busy,
    required this.message,
    required this.error,
    required this.searchResponse,
    required this.organisedDocument,
    required this.suggestedDestination,
    required this.unresolvedCategory,
    required this.categoryMatchAmbiguous,
    required this.uploadedName,
    required this.onSend,
    required this.onUpload,
    required this.onClearAttachment,
    required this.onSaveSuggestion,
    required this.onCreateAndSaveCategory,
    required this.onChooseUploadCategory,
    required this.onCancelCategoryChoice,
    required this.onRetry,
    required this.analysisFailure,
    required this.onSaveWithoutReading,
    required this.onChooseCategory,
    required this.onDismissAnalysis,
    required this.email,
    required this.onSignOut,
  });
  final int tab;
  final ValueChanged<int> onTab;
  final TextEditingController query;
  final bool busy;
  final String? message;
  final String? error;
  final SearchResponse? searchResponse;
  final OrganisedDocument? organisedDocument;
  final String? suggestedDestination;
  final String? unresolvedCategory;
  final bool categoryMatchAmbiguous;
  final String? uploadedName;
  final VoidCallback onSend,
      onUpload,
      onClearAttachment,
      onSaveSuggestion,
      onCreateAndSaveCategory,
      onChooseUploadCategory,
      onCancelCategoryChoice,
      onRetry,
      onSaveWithoutReading,
      onChooseCategory,
      onDismissAnalysis;
  final bool analysisFailure;
  final String email;
  final Future<void> Function() onSignOut;
  static const labels = ['Home', 'Timeline', 'Library', 'Inbox', 'Reminders'];
  static const icons = [
    Icons.home_outlined,
    Icons.schedule_outlined,
    Icons.folder_outlined,
    Icons.inbox_outlined,
    Icons.notifications_outlined,
  ];

  Widget profileMenu(BuildContext context) => PopupMenuButton<String>(
    key: const ValueKey('profile-avatar'),
    tooltip: 'Open profile menu',
    icon: CircleAvatar(
      radius: 20,
      backgroundColor: const Color(0xffdce8ff),
      foregroundColor: const Color(0xff245cc5),
      child: Text(_initials(email)),
    ),
    onSelected: (value) {
      if (value == 'signout') onSignOut();
      if (value == 'settings') {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => Scaffold(
              appBar: AppBar(title: const Text('Settings')),
              body: const Center(
                child: Text('Settings will be connected in Phase 2.'),
              ),
            ),
          ),
        );
      }
    },
    itemBuilder: (_) => const [
      PopupMenuItem(value: 'settings', child: Text('Settings')),
      PopupMenuItem(value: 'signout', child: Text('Sign out')),
    ],
  );

  @override
  Widget build(BuildContext c) {
    final wide = MediaQuery.sizeOf(c).width >= 720;
    final content = tab == 0
        ? Home(
            query: query,
            busy: busy,
            message: message,
            error: error,
            searchResponse: searchResponse,
            organisedDocument: organisedDocument,
            suggestedDestination: suggestedDestination,
            unresolvedCategory: unresolvedCategory,
            categoryMatchAmbiguous: categoryMatchAmbiguous,
            uploadedName: uploadedName,
            onSend: onSend,
            onUpload: onUpload,
            onClearAttachment: onClearAttachment,
            onSaveSuggestion: onSaveSuggestion,
            onCreateAndSaveCategory: onCreateAndSaveCategory,
            onChooseUploadCategory: onChooseUploadCategory,
            onCancelCategoryChoice: onCancelCategoryChoice,
            onRetry: onRetry,
            analysisFailure: analysisFailure,
            onSaveWithoutReading: onSaveWithoutReading,
            onChooseCategory: onChooseCategory,
            onDismissAnalysis: onDismissAnalysis,
          )
        : Center(child: Text('${labels[tab]} will be connected in Phase 2.'));
    final main = Column(
      children: [
        Container(
          height: 72,
          padding: const EdgeInsets.symmetric(horizontal: 32),
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(bottom: BorderSide(color: Color(0xffe3e8ef))),
          ),
          child: Row(
            children: [
              Text(
                labels[tab],
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: Color(0xff17233a),
                ),
              ),
              const Spacer(),
              profileMenu(c),
            ],
          ),
        ),
        Expanded(child: content),
      ],
    );
    return Scaffold(
      backgroundColor: const Color(0xfffbfcfe),
      body: SafeArea(
        bottom: false,
        child: wide
            ? Row(
                children: [
                  _DesktopSidebar(
                    selected: tab,
                    onSelected: onTab,
                    email: email,
                  ),
                  Expanded(child: main),
                ],
              )
            : main,
      ),
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: tab,
              onDestinationSelected: onTab,
              destinations: List.generate(
                5,
                (i) => NavigationDestination(
                  icon: Icon(icons[i]),
                  label: labels[i],
                ),
              ),
            ),
    );
  }

  static String _initials(String e) => e
      .split('@')
      .first
      .split(RegExp(r'[._ -]+'))
      .where((x) => x.isNotEmpty)
      .take(2)
      .map((x) => x[0].toUpperCase())
      .join();
}

class _DesktopSidebar extends StatelessWidget {
  const _DesktopSidebar({
    required this.selected,
    required this.onSelected,
    required this.email,
  });
  final int selected;
  final ValueChanged<int> onSelected;
  final String email;

  @override
  Widget build(BuildContext context) => Container(
    width: 238,
    padding: const EdgeInsets.fromLTRB(16, 24, 16, 18),
    decoration: const BoxDecoration(
      color: Colors.white,
      border: Border(right: BorderSide(color: Color(0xffe3e8ef))),
    ),
    child: Column(
      children: [
        const Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: Color(0xff123f78),
              foregroundColor: Colors.white,
              child: Text('F', style: TextStyle(fontWeight: FontWeight.w700)),
            ),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'FamilyDocuments',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
        const SizedBox(height: 30),
        ...List.generate(
          Shell.labels.length,
          (index) => Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Material(
              color: Colors.transparent,
              child: ListTile(
                selected: selected == index,
                selectedTileColor: const Color(0xffeaf0ff),
                selectedColor: const Color(0xff245cc5),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                leading: Icon(Shell.icons[index], size: 21),
                title: Text(Shell.labels[index]),
                onTap: () => onSelected(index),
              ),
            ),
          ),
        ),
        const Spacer(),
        const Divider(),
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 10),
          leading: CircleAvatar(
            radius: 18,
            backgroundColor: const Color(0xffdce8ff),
            child: Text(Shell._initials(email)),
          ),
          title: Text(
            email.split('@').first,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: const Text('Family'),
        ),
      ],
    ),
  );
}

class Home extends StatelessWidget {
  const Home({
    super.key,
    required this.query,
    required this.busy,
    required this.message,
    required this.error,
    required this.searchResponse,
    required this.organisedDocument,
    required this.suggestedDestination,
    required this.unresolvedCategory,
    required this.categoryMatchAmbiguous,
    required this.uploadedName,
    required this.onSend,
    required this.onUpload,
    required this.onClearAttachment,
    required this.onSaveSuggestion,
    required this.onCreateAndSaveCategory,
    required this.onChooseUploadCategory,
    required this.onCancelCategoryChoice,
    required this.onRetry,
    required this.analysisFailure,
    required this.onSaveWithoutReading,
    required this.onChooseCategory,
    required this.onDismissAnalysis,
  });
  final TextEditingController query;
  final bool busy;
  final String? message;
  final String? error;
  final SearchResponse? searchResponse;
  final OrganisedDocument? organisedDocument;
  final String? suggestedDestination;
  final String? unresolvedCategory;
  final bool categoryMatchAmbiguous;
  final String? uploadedName;
  final VoidCallback onSend,
      onUpload,
      onClearAttachment,
      onSaveSuggestion,
      onCreateAndSaveCategory,
      onChooseUploadCategory,
      onCancelCategoryChoice,
      onRetry,
      onSaveWithoutReading,
      onChooseCategory,
      onDismissAnalysis;
  final bool analysisFailure;
  @override
  Widget build(BuildContext c) => LayoutBuilder(
    builder: (context, constraints) {
      final startingConversation =
          message == null &&
          searchResponse == null &&
          organisedDocument == null &&
          error == null;
      if (startingConversation) {
        return _InitialConversation(
          query: query,
          busy: busy,
          uploadedName: uploadedName,
          onSend: onSend,
          onUpload: onUpload,
          onClearAttachment: onClearAttachment,
        );
      }
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 780),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 18),
            child: Column(
              children: [
                const Spacer(flex: 3),
                if (message == null &&
                    searchResponse == null &&
                    organisedDocument == null &&
                    error == null) ...[
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: const Color(0xff123f78),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Icon(Icons.auto_awesome, color: Colors.white),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'What do you need?',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 30,
                      height: 1.15,
                      fontWeight: FontWeight.w700,
                      color: Color(0xff071a36),
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Add something or ask about anything you’ve saved.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 16, color: Color(0xff64748b)),
                  ),
                  const SizedBox(height: 24),
                ],
                if (message != null)
                  Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      border: Border.all(color: const Color(0xffe3e8ef)),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(message!),
                          if (suggestedDestination != null) ...[
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 8,
                              children: [
                                FilledButton(
                                  onPressed: busy ? null : onSaveSuggestion,
                                  child: const Text('Save there'),
                                ),
                                OutlinedButton(
                                  onPressed: busy ? null : onClearAttachment,
                                  child: const Text('Choose category'),
                                ),
                              ],
                            ),
                          ],
                          if (unresolvedCategory != null) ...[
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                if (!categoryMatchAmbiguous)
                                  FilledButton(
                                    onPressed: busy
                                        ? null
                                        : onCreateAndSaveCategory,
                                    child: const Text('Create and save'),
                                  ),
                                OutlinedButton(
                                  onPressed: busy
                                      ? null
                                      : onChooseUploadCategory,
                                  child: const Text('Choose another category'),
                                ),
                                TextButton(
                                  onPressed: busy
                                      ? null
                                      : onCancelCategoryChoice,
                                  child: const Text('Cancel'),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                if (searchResponse != null)
                  _SearchResult(result: searchResponse!),
                if (organisedDocument != null)
                  _AnalysisResult(
                    result: organisedDocument!,
                    fileName: uploadedName,
                  ),
                if (error != null)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xfffff7f7),
                      border: Border.all(color: const Color(0xfff3c4c4)),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(
                              Icons.error_outline,
                              color: Color(0xffa72d2d),
                            ),
                            const SizedBox(width: 12),
                            Expanded(child: Text(error!)),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          children: [
                            TextButton(
                              onPressed: busy ? null : onRetry,
                              child: Text(
                                analysisFailure ? 'Retry reading' : 'Retry',
                              ),
                            ),
                            if (analysisFailure) ...[
                              TextButton(
                                onPressed: onSaveWithoutReading,
                                child: const Text('Save without reading'),
                              ),
                              TextButton(
                                onPressed: onChooseCategory,
                                child: const Text('Choose category'),
                              ),
                              TextButton(
                                onPressed: onDismissAnalysis,
                                child: const Text('Dismiss'),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                if (message == null &&
                    searchResponse == null &&
                    organisedDocument == null &&
                    error == null &&
                    !busy)
                  const SizedBox(height: 8),
                const Spacer(flex: 5),
                if (busy)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: Text('Searching…'),
                  ),
                if (uploadedName != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: InputChip(
                        avatar: const Icon(Icons.attach_file, size: 18),
                        label: Text(uploadedName!),
                        onDeleted: onClearAttachment,
                      ),
                    ),
                  ),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border.all(color: const Color(0xffcfd8e6)),
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x100f2748),
                        blurRadius: 24,
                        offset: Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      IconButton.filledTonal(
                        onPressed: onUpload,
                        tooltip: 'Upload document',
                        icon: const Icon(Icons.attach_file),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: TextField(
                          controller: query,
                          onSubmitted: (_) => onSend(),
                          decoration: const InputDecoration(
                            hintText: 'Attach, save, or ask about anything…',
                            border: InputBorder.none,
                            filled: false,
                          ),
                        ),
                      ),
                      IconButton.filled(
                        onPressed: busy ? null : onSend,
                        tooltip: 'Send',
                        style: IconButton.styleFrom(
                          backgroundColor: const Color(0xff123f78),
                          foregroundColor: Colors.white,
                        ),
                        icon: const Icon(Icons.send_outlined),
                      ),
                    ],
                  ),
                ),
                if (message == null &&
                    searchResponse == null &&
                    organisedDocument == null &&
                    error == null &&
                    !busy) ...[
                  const SizedBox(height: 12),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 8,
                    runSpacing: 8,
                    children:
                        [
                              'Add to Rental 1',
                              'Read this bill as an invoice',
                              'Add reminder Doctor appointment',
                            ]
                            .map(
                              (s) => ActionChip(
                                label: Text(s),
                                onPressed: () => query.text = s,
                              ),
                            )
                            .toList(),
                  ),
                ],
                const SizedBox(height: 10),
                const Text(
                  'Your documents stay private to your family.',
                  style: TextStyle(fontSize: 11, color: Color(0xff8190a5)),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _InitialConversation extends StatelessWidget {
  const _InitialConversation({
    required this.query,
    required this.busy,
    required this.uploadedName,
    required this.onSend,
    required this.onUpload,
    required this.onClearAttachment,
  });
  final TextEditingController query;
  final bool busy;
  final String? uploadedName;
  final VoidCallback onSend, onUpload, onClearAttachment;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 780),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'What do you need?',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w600,
                color: Color(0xff071a36),
              ),
            ),
            const SizedBox(height: 28),
            if (uploadedName != null)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: InputChip(
                    avatar: const Icon(Icons.attach_file, size: 18),
                    label: Text(uploadedName!),
                    onDeleted: onClearAttachment,
                  ),
                ),
              ),
            _ConversationComposer(
              query: query,
              busy: busy,
              onSend: onSend,
              onUpload: onUpload,
            ),
            const SizedBox(height: 26),
            ...[
              (Icons.folder_outlined, 'Add this to Rental 1'),
              (Icons.receipt_long_outlined, 'Read this bill as an invoice'),
              (Icons.notifications_outlined, 'Add reminder Doctor appointment'),
            ].map(
              (example) => Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => query.text = example.$2,
                  icon: Icon(
                    example.$1,
                    size: 19,
                    color: const Color(0xff64748b),
                  ),
                  label: Text(
                    example.$2,
                    style: const TextStyle(color: Color(0xff64748b)),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _ConversationComposer extends StatelessWidget {
  const _ConversationComposer({
    required this.query,
    required this.busy,
    required this.onSend,
    required this.onUpload,
  });
  final TextEditingController query;
  final bool busy;
  final VoidCallback onSend, onUpload;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(8),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: const Color(0xffcfd8e6)),
      borderRadius: BorderRadius.circular(24),
      boxShadow: const [
        BoxShadow(
          color: Color(0x100f2748),
          blurRadius: 24,
          offset: Offset(0, 8),
        ),
      ],
    ),
    child: Row(
      children: [
        IconButton.filledTonal(
          onPressed: onUpload,
          tooltip: 'Attach a document',
          icon: const Icon(Icons.add),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: TextField(
            controller: query,
            onSubmitted: (_) => onSend(),
            decoration: const InputDecoration(
              hintText: 'Attach, save, or ask about anything…',
              border: InputBorder.none,
              filled: false,
            ),
          ),
        ),
        IconButton.filled(
          onPressed: busy ? null : onSend,
          tooltip: 'Send',
          style: IconButton.styleFrom(
            backgroundColor: const Color(0xff123f78),
            foregroundColor: Colors.white,
          ),
          icon: const Icon(Icons.send_outlined),
        ),
      ],
    ),
  );
}

class _SearchResult extends StatelessWidget {
  const _SearchResult({required this.result});
  final SearchResponse result;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: const Color(0xffe3e8ef)),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(result.answer),
        if (result.documents.isEmpty) ...[
          const SizedBox(height: 12),
          const Text(
            'No matching documents were found.',
            style: TextStyle(color: Color(0xff64748b)),
          ),
        ],
        ...result.documents.map(
          (document) => ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.description_outlined),
            title: Text(document.title),
            subtitle: Text(
              [
                document.collection,
                document.date,
              ].whereType<String>().join(' · '),
            ),
            trailing: const Text('Open'),
          ),
        ),
      ],
    ),
  );
}

class _AnalysisResult extends StatelessWidget {
  const _AnalysisResult({required this.result, this.fileName});
  final OrganisedDocument result;
  final String? fileName;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: const Color(0xffe3e8ef)),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(result.title, style: const TextStyle(fontWeight: FontWeight.w700)),
        if (fileName != null && fileName != result.title) ...[
          const SizedBox(height: 2),
          Text(fileName!, style: const TextStyle(color: Color(0xff64748b))),
        ],
        const SizedBox(height: 4),
        const Text(
          'Saved and organised for your Family.',
          style: TextStyle(color: Color(0xff64748b)),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            result.category,
            ...result.tags,
          ].map((value) => Chip(label: Text(value))).toList(),
        ),
      ],
    ),
  );
}
