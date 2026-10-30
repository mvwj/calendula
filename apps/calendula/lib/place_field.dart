import 'dart:math';

import 'package:flutter/material.dart';

import 'address_index.dart';
import 'place_search.dart';

class PlaceField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final FocusNode focus;
  final StopSearch stops;
  final AddressIndex? addresses;
  final VoidCallback? onChanged, onSelected;
  const PlaceField({
    super.key,
    required this.label,
    required this.controller,
    required this.focus,
    required this.stops,
    this.addresses,
    this.onChanged,
    this.onSelected,
  });
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) => RawAutocomplete<String>(
      textEditingController: controller,
      focusNode: focus,
      optionsBuilder: (value) => [
        ...stops.search(value.text, limit: 8),
        ...?addresses?.search(value.text, limit: 5).map((a) => a.label),
      ],
      onSelected: (_) => onSelected?.call(),
      fieldViewBuilder: (context, c, node, submit) => TextField(
        controller: c,
        focusNode: node,
        maxLength: 300,
        textInputAction: TextInputAction.search,
        onSubmitted: (_) => submit(),
        decoration: InputDecoration(
          labelText: label,
          counterText: '',
          hintText: 'Stop or Prague street address',
          suffixIcon: IconButton(
            tooltip: 'Clear',
            icon: const Icon(Icons.close),
            onPressed: () {
              c.clear();
              node.requestFocus();
              onChanged?.call();
            },
          ),
        ),
        onChanged: (_) => onChanged?.call(),
      ),
      optionsViewBuilder: (context, select, options) {
        final choices = options.toList(),
            selected = AutocompleteHighlightedOption.of(context);
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 6,
            borderRadius: BorderRadius.circular(16),
            clipBehavior: Clip.antiAlias,
            child: SizedBox(
              width: box.maxWidth,
              height: min(choices.length * 62.0, 230),
              child: ListView.builder(
                padding: EdgeInsets.zero,
                itemCount: choices.length,
                itemBuilder: (context, i) => ListTile(
                  selected: selected == i,
                  dense: true,
                  leading: Icon(
                    stops.names.contains(choices[i])
                        ? Icons.directions_transit
                        : Icons.place_outlined,
                  ),
                  title: Text(
                    choices[i],
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => select(choices[i]),
                ),
              ),
            ),
          ),
        );
      },
    ),
  );
}
