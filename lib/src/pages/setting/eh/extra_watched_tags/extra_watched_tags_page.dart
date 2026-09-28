import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/service/tag_translation_service.dart';
import 'package:jhentai/src/setting/extra_watched_tag_setting.dart';

import '../../../../utils/toast_util.dart';

/// Manage locally stored watched tags which are merged into the Watched page.
class ExtraWatchedTagsPage extends StatefulWidget {
  const ExtraWatchedTagsPage({Key? key}) : super(key: key);

  @override
  State<ExtraWatchedTagsPage> createState() => _ExtraWatchedTagsPageState();
}

class _ExtraWatchedTagsPageState extends State<ExtraWatchedTagsPage> {
  final TextEditingController controller = TextEditingController();

  List<TagAutoCompletionMatch> suggestions = [];

  /// used to drop outdated async results
  int searchToken = 0;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Future<void> _onChanged(String text) async {
    int token = ++searchToken;

    if (text.trim().length < 2) {
      setState(() => suggestions = []);
      return;
    }

    List<TagAutoCompletionMatch> result = await tagTranslationService.searchTags(text.trim(), limit: 12);
    if (!mounted || token != searchToken) {
      return;
    }
    setState(() => suggestions = result);
  }

  Future<void> _add(String tag) async {
    bool success = await extraWatchedTagSetting.addTag(tag);
    if (!success) {
      toast('extraWatchedTagsAddFailed'.tr);
      return;
    }
    controller.clear();
    setState(() => suggestions = []);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(centerTitle: true, title: Text('extraWatchedTags'.tr)),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text('extraWatchedTagsDesc'.tr, style: Theme.of(context).textTheme.bodySmall),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: TextField(
              controller: controller,
              onChanged: _onChanged,
              onSubmitted: _add,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                isDense: true,
                border: const OutlineInputBorder(),
                hintText: 'extraWatchedTagsInputHint'.tr,
                suffixIcon: IconButton(icon: const Icon(Icons.add), onPressed: () => _add(controller.text)),
              ),
            ),
          ),
          ...suggestions.map(_buildSuggestion),
          const Divider(),
          Obx(() {
            List<String> tags = extraWatchedTagSetting.tags.toList();
            if (tags.isEmpty) {
              return Padding(
                padding: const EdgeInsets.all(32),
                child: Center(child: Text('extraWatchedTagsEmpty'.tr)),
              );
            }
            return Column(children: tags.map(_buildTagTile).toList());
          }),
        ],
      ),
    );
  }

  Widget _buildSuggestion(TagAutoCompletionMatch match) {
    String tag = '${match.tagData.namespace}:${match.tagData.key}';
    String? translated = match.tagData.tagName;
    return ListTile(
      dense: true,
      title: Text(tag),
      subtitle: translated == null ? null : Text('${match.tagData.translatedNamespace ?? ''}:$translated'),
      trailing: const Icon(Icons.add_circle_outline),
      onTap: () => _add(tag),
    );
  }

  Widget _buildTagTile(String tag) {
    return ListTile(
      title: Text(tag),
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline),
        onPressed: () => extraWatchedTagSetting.removeTag(tag),
      ),
    );
  }
}
