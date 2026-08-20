<script setup lang="ts">
import { createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { ComarkRenderer } from "comark/react/components/ComarkRenderer";
import { onBeforeUnmount, onMounted, ref, watch } from "vue";
import type { ComarkTree } from "md4x/wasm";

const props = defineProps<{
  tree: ComarkTree | null;
  components?: Record<string, any>;
}>();

const containerEl = ref<HTMLElement | null>(null);
let reactRoot: Root | null = null;

const RawHtml = ({ __node: [, nodeProps, ...children] }: any) =>
  createElement(nodeProps.block ? "div" : "span", {
    dangerouslySetInnerHTML: { __html: children.join("") },
  });

function renderTree() {
  if (!containerEl.value) return;
  if (!reactRoot) reactRoot = createRoot(containerEl.value);

  if (!props.tree) {
    reactRoot.render(createElement("div"));
    return;
  }

  reactRoot.render(
    createElement(ComarkRenderer, {
      tree: props.tree,
      components: { ...props.components, html: RawHtml },
    } as any),
  );
}

onMounted(renderTree);
watch(() => props.tree, renderTree);

onBeforeUnmount(() => {
  reactRoot?.unmount();
  reactRoot = null;
});
</script>

<template>
  <div ref="containerEl" />
</template>
