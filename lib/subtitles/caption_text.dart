import 'package:flutter/material.dart';

import '../translation/translation_controller.dart';

class CaptionText extends StatelessWidget {
  const CaptionText({
    super.key,
    required this.originals,
    required this.placeholder,
    this.translation,
  });
  final List<String> originals;
  final String placeholder;
  final TranslationController? translation;
  @override
  Widget build(BuildContext context) {
    final translated =
        translation?.enabled == true && translation!.translations.isNotEmpty;
    return SingleChildScrollView(
      child: originals.isEmpty
          ? Text(
              placeholder,
              style: const TextStyle(
                fontSize: 17,
                height: 1.5,
                color: Color(0xff708196),
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (int i = 0; i < originals.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SelectableText(
                          originals[i],
                          key: Key('audio-original-$i'),
                          style: TextStyle(
                            fontSize: translated ? 14 : 18,
                            height: 1.5,
                            color: translated
                                ? const Color(0xff708196)
                                : const Color(0xff243247),
                          ),
                        ),
                        if (translated &&
                            i < translation!.translations.length &&
                            translation!.originals[i] == originals[i])
                          SelectableText(
                            translation!.translations[i],
                            key: Key('audio-translated-$i'),
                            style: const TextStyle(
                              fontSize: 19,
                              height: 1.5,
                              color: Color(0xff243247),
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}
