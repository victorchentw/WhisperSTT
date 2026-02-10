Nexa bundled models

This app expects Nexa ASR model folders under:
  WhisperiOS/Models/nexa/<model-id>/

Official STT model (per Nexa iOS docs):
  - NexaAI/parakeet-tdt-0.6b-v3-ane

Current repo status:
  - Default model is already bundled at:
    WhisperiOS/Models/nexa/parakeet-tdt-0.6b-v3-ane
  - App bundle resource path at runtime is:
    <App>.app/nexa/parakeet-tdt-0.6b-v3-ane

Refresh workflow (if you need to re-download):
  1) Remove the existing parakeet folder.
  2) Download files from:
       https://huggingface.co/NexaAI/parakeet-tdt-0.6b-v3-ane
  3) Put files under:
       WhisperiOS/Models/nexa/parakeet-tdt-0.6b-v3-ane
  4) Rebuild the app.
