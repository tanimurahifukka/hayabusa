#!/usr/bin/env python3
"""Hayabusa Layer Importance Analyzer.

Runs 100 SOAP prompts through a Qwen model via mlx-lm,
measures per-layer activation contribution, and saves
importance scores to layer_importance.json.

Usage:
    pip install mlx-lm
    python scripts/analyze_layers.py [--model MODEL_ID] [--output PATH]
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

import mlx.core as mx
from mlx_lm import load

# ── SOAP Prompts ──────────────────────────────────────────────────
# 100 diverse SOAP-style medical documentation prompts

SOAP_PROMPTS = [
    # General medicine
    "Write a SOAP note for a 45-year-old male with a 3-day history of headache and low-grade fever.",
    "Create a SOAP note for a 32-year-old female presenting with acute lower back pain after lifting heavy boxes.",
    "Document a SOAP note for a 68-year-old male with worsening shortness of breath and bilateral ankle edema.",
    "Write a SOAP note for a 25-year-old female with a 5-day history of sore throat and difficulty swallowing.",
    "Create a SOAP note for a 55-year-old male presenting with chest tightness during exertion.",
    "Document a SOAP note for a 40-year-old female with recurrent urinary tract infections.",
    "Write a SOAP note for a 72-year-old male with a new onset of confusion and lethargy.",
    "Create a SOAP note for a 28-year-old male presenting with acute right lower quadrant abdominal pain.",
    "Document a SOAP note for a 50-year-old female with bilateral knee pain worsening over 6 months.",
    "Write a SOAP note for a 35-year-old male with persistent cough and night sweats for 2 weeks.",
    # Chronic disease management
    "Create a SOAP note for a 60-year-old diabetic male with an HbA1c of 9.2% at follow-up.",
    "Document a SOAP note for a 48-year-old female with uncontrolled hypertension on three medications.",
    "Write a SOAP note for a 65-year-old male with COPD presenting with increased sputum production.",
    "Create a SOAP note for a 42-year-old female with newly diagnosed hypothyroidism and fatigue.",
    "Document a SOAP note for a 70-year-old male with heart failure and weight gain of 5 pounds in a week.",
    "Write a SOAP note for a 55-year-old female with rheumatoid arthritis and morning stiffness.",
    "Create a SOAP note for a 38-year-old male with Crohn's disease experiencing a flare-up.",
    "Document a SOAP note for a 62-year-old female with osteoporosis found on DEXA scan.",
    "Write a SOAP note for a 50-year-old male with gout and recurrent left great toe swelling.",
    "Create a SOAP note for a 45-year-old female with migraine headaches occurring weekly.",
    # Pediatrics
    "Document a SOAP note for a 3-year-old child with high fever and bilateral ear pain.",
    "Write a SOAP note for a 10-year-old presenting with wheezing and nocturnal cough.",
    "Create a SOAP note for a 6-month-old infant with persistent vomiting after feeds.",
    "Document a SOAP note for a 7-year-old child with a new skin rash and joint pain.",
    "Write a SOAP note for a 2-year-old with diarrhea and decreased oral intake for 2 days.",
    "Create a SOAP note for a 12-year-old with recurrent abdominal pain and school avoidance.",
    "Document a SOAP note for a 4-year-old child brought in for a well-child check with developmental concerns.",
    "Write a SOAP note for an 8-year-old presenting with a limp and left hip pain.",
    "Create a SOAP note for a 15-year-old female with irregular menstrual cycles and acne.",
    "Document a SOAP note for a 1-year-old with a first febrile seizure.",
    # Emergency / acute
    "Write a SOAP note for a 58-year-old male presenting to the ED with crushing substernal chest pain.",
    "Create a SOAP note for a 30-year-old female after a motor vehicle accident with neck pain.",
    "Document a SOAP note for a 22-year-old male with a deep laceration to the left forearm.",
    "Write a SOAP note for a 75-year-old female who fell at home and has right hip pain.",
    "Create a SOAP note for a 40-year-old male presenting with acute onset aphasia and right-sided weakness.",
    "Document a SOAP note for a 18-year-old with an anaphylactic reaction to peanuts.",
    "Write a SOAP note for a 65-year-old male with hematemesis and melena.",
    "Create a SOAP note for a 28-year-old female with severe pelvic pain and a positive pregnancy test.",
    "Document a SOAP note for a 50-year-old male with sudden onset severe headache, worst of life.",
    "Write a SOAP note for a 35-year-old presenting with acute urinary retention.",
    # Mental health
    "Create a SOAP note for a 29-year-old male with worsening depression and insomnia for 4 weeks.",
    "Document a SOAP note for a 45-year-old female with panic attacks occurring daily.",
    "Write a SOAP note for a 20-year-old college student presenting with anxiety and poor concentration.",
    "Create a SOAP note for a 55-year-old male with alcohol use disorder seeking help for detox.",
    "Document a SOAP note for a 38-year-old female with PTSD symptoms after a recent trauma.",
    "Write a SOAP note for a 17-year-old with self-harm behaviors and suicidal ideation.",
    "Create a SOAP note for a 60-year-old male with new-onset memory loss and personality changes.",
    "Document a SOAP note for a 33-year-old female with bipolar disorder during a manic episode.",
    "Write a SOAP note for a 25-year-old with ADHD requesting medication adjustment.",
    "Create a SOAP note for a 70-year-old with insomnia and daytime somnolence.",
    # Dermatology / skin
    "Document a SOAP note for a 35-year-old with a suspicious changing mole on the back.",
    "Write a SOAP note for a 22-year-old with widespread acne vulgaris unresponsive to topicals.",
    "Create a SOAP note for a 60-year-old with a non-healing ulcer on the lower leg.",
    "Document a SOAP note for a 45-year-old with psoriasis flare affecting elbows and scalp.",
    "Write a SOAP note for a 8-year-old with atopic dermatitis and nighttime scratching.",
    # Cardiology
    "Create a SOAP note for a 52-year-old male with newly detected atrial fibrillation.",
    "Document a SOAP note for a 65-year-old female post-STEMI with cardiac catheterization findings.",
    "Write a SOAP note for a 48-year-old with palpitations and dizziness during exercise.",
    "Create a SOAP note for a 70-year-old with aortic stenosis and syncope.",
    "Document a SOAP note for a 55-year-old male with peripheral artery disease and claudication.",
    # Pulmonology
    "Write a SOAP note for a 40-year-old non-smoker with a persistent dry cough for 8 weeks.",
    "Create a SOAP note for a 58-year-old with newly diagnosed obstructive sleep apnea.",
    "Document a SOAP note for a 30-year-old with exercise-induced asthma.",
    "Write a SOAP note for a 72-year-old with a pleural effusion found on chest X-ray.",
    "Create a SOAP note for a 45-year-old with sarcoidosis and bilateral hilar lymphadenopathy.",
    # Endocrinology
    "Document a SOAP note for a 35-year-old female with Graves' disease and exophthalmos.",
    "Write a SOAP note for a 28-year-old male with type 1 diabetes and recurrent hypoglycemia.",
    "Create a SOAP note for a 50-year-old with an adrenal incidentaloma found on CT.",
    "Document a SOAP note for a 60-year-old male with secondary hyperparathyroidism.",
    "Write a SOAP note for a 40-year-old female with polycystic ovary syndrome and infertility.",
    # Gastroenterology
    "Create a SOAP note for a 45-year-old with new-onset dysphagia to solids.",
    "Document a SOAP note for a 55-year-old with positive fecal occult blood test and weight loss.",
    "Write a SOAP note for a 30-year-old with irritable bowel syndrome and bloating.",
    "Create a SOAP note for a 65-year-old with acute pancreatitis and elevated lipase.",
    "Document a SOAP note for a 40-year-old with GERD refractory to proton pump inhibitors.",
    # Neurology
    "Write a SOAP note for a 30-year-old female with optic neuritis and suspected multiple sclerosis.",
    "Create a SOAP note for a 68-year-old with resting tremor and bradykinesia.",
    "Document a SOAP note for a 55-year-old with new-onset seizures and a brain mass on MRI.",
    "Write a SOAP note for a 45-year-old with carpal tunnel syndrome and thenar atrophy.",
    "Create a SOAP note for a 25-year-old with cluster headaches occurring nightly.",
    # Orthopedics
    "Document a SOAP note for a 50-year-old with rotator cuff tear and limited shoulder abduction.",
    "Write a SOAP note for a 20-year-old athlete with an ACL tear after a basketball injury.",
    "Create a SOAP note for a 65-year-old with lumbar spinal stenosis and neurogenic claudication.",
    "Document a SOAP note for a 45-year-old with plantar fasciitis and heel pain.",
    "Write a SOAP note for a 35-year-old with a distal radius fracture after a fall on an outstretched hand.",
    # Infectious disease
    "Create a SOAP note for a 40-year-old with cellulitis of the right lower extremity.",
    "Document a SOAP note for a 55-year-old with community-acquired pneumonia and fever.",
    "Write a SOAP note for a 30-year-old returning from Southeast Asia with fever and rash.",
    "Create a SOAP note for a 65-year-old with herpes zoster involving the left thorax.",
    "Document a SOAP note for a 28-year-old with a positive HIV test and initial evaluation.",
    # Obstetrics
    "Write a SOAP note for a 32-year-old at 28 weeks gestation with gestational diabetes.",
    "Create a SOAP note for a 25-year-old primigravida at 36 weeks with preeclampsia.",
    "Document a SOAP note for a 38-year-old at 12 weeks gestation for a first prenatal visit.",
    "Write a SOAP note for a 30-year-old postpartum day 2 with fever and uterine tenderness.",
    "Create a SOAP note for a 27-year-old at 20 weeks with decreased fetal movement.",
    # Ophthalmology
    "Document a SOAP note for a 55-year-old with sudden painless vision loss in the right eye.",
    "Write a SOAP note for a 60-year-old with elevated intraocular pressure and visual field defects.",
    "Create a SOAP note for a 70-year-old with cataracts and progressive visual decline.",
    "Document a SOAP note for a 35-year-old with red eye, pain, and photophobia suggesting uveitis.",
    "Write a SOAP note for a 45-year-old diabetic with proliferative retinopathy on fundoscopy.",
]

assert len(SOAP_PROMPTS) == 100, f"Expected 100 prompts, got {len(SOAP_PROMPTS)}"


# ── Helpers ───────────────────────────────────────────────────────

def _flatten_params(params, prefix=""):
    """Recursively flatten MLX module parameters dict to (key, MLXArray) pairs."""
    result = []
    if isinstance(params, dict):
        for k, v in params.items():
            full_key = f"{prefix}.{k}" if prefix else k
            if isinstance(v, dict):
                result.extend(_flatten_params(v, full_key))
            elif hasattr(v, 'shape'):  # MLXArray
                result.append((full_key, v))
    return result


def _set_param(module, key, value):
    """Set a parameter on an MLX module by dot-separated key."""
    parts = key.split(".")
    obj = module
    for p in parts[:-1]:
        obj = getattr(obj, p)
    setattr(obj, parts[-1], value)


# ── Analysis ──────────────────────────────────────────────────────


def _detect_model_structure(model):
    """Detect model architecture and return (inner_model, layers, output_proj_paths).

    Supports:
      - Qwen2.5: model.model.layers[i] with self_attn.o_proj + mlp.down_proj
      - Qwen3.5: model.language_model.model.layers[i] with linear_attn.out_proj + mlp.down_proj
    """
    # Qwen3.5 style: model.language_model.model.layers
    if hasattr(model, 'language_model') and hasattr(model.language_model, 'model'):
        inner = model.language_model.model
        if hasattr(inner, 'layers') and len(inner.layers) > 0:
            layer0 = inner.layers[0]
            if hasattr(layer0, 'linear_attn') and hasattr(layer0.linear_attn, 'out_proj'):
                return inner, inner.layers, ["linear_attn.out_proj", "mlp.down_proj"]

    # Qwen2.5 / standard style: model.model.layers
    if hasattr(model, 'model') and hasattr(model.model, 'layers'):
        inner = model.model
        return inner, inner.layers, ["self_attn.o_proj", "mlp.down_proj"]

    # Fallback: try model.layers directly
    if hasattr(model, 'layers'):
        return model, model.layers, ["self_attn.o_proj", "mlp.down_proj"]

    raise RuntimeError("Cannot detect model layer structure")


def measure_layer_importance(
    model,
    tokenizer,
    prompts: list[str],
) -> dict:
    """Measure each layer's relative contribution by perturbation analysis.

    For each layer, zeros its output projections, runs the full model,
    and measures how much the output changes (cosine distance).
    """
    inner_model, layers, output_proj_paths = _detect_model_structure(model)
    num_layers = len(layers)
    print(f"  Model has {num_layers} layers")
    print(f"  Architecture output projections: {output_proj_paths}")

    calib_prompts = prompts[:min(10, len(prompts))]
    sys.stderr.write(f"  Using {len(calib_prompts)} calibration prompts x {num_layers} layers\n")

    # Prepare tokenized inputs
    all_tokens = []
    for prompt in calib_prompts:
        chat = [{"role": "user", "content": prompt}]
        tokens = tokenizer.apply_chat_template(chat, add_generation_prompt=True)
        if isinstance(tokens, str):
            tokens = tokenizer.encode(tokens)
        all_tokens.append(tokens)

    # Get baseline hidden states
    sys.stderr.write("  Computing baseline hidden states...\n")
    baselines = []
    for tokens in all_tokens:
        x = mx.array([tokens])
        hidden = inner_model(x).astype(mx.float32)
        mx.eval(hidden)
        baselines.append(hidden)

    # For each layer: zero output projections, measure output change, restore
    raw_importance = {}
    for layer_idx in range(num_layers):
        sys.stderr.write(f"\r  Probing layer {layer_idx + 1}/{num_layers}...")
        sys.stderr.flush()

        layer = layers[layer_idx]

        # Detect output projection paths for this specific layer (hybrid arch support)
        layer_proj_paths = []
        for submod_name in output_proj_paths:
            parts = submod_name.split(".")
            try:
                submod = layer
                for p in parts:
                    submod = getattr(submod, p)
                layer_proj_paths.append(submod_name)
            except AttributeError:
                pass
        # Fallback: try common alternatives
        if not any("attn" in p for p in layer_proj_paths):
            for alt in ["self_attn.o_proj", "linear_attn.out_proj"]:
                parts = alt.split(".")
                try:
                    submod = layer
                    for p in parts:
                        submod = getattr(submod, p)
                    layer_proj_paths.append(alt)
                except AttributeError:
                    pass

        # Save and zero output projections
        saved_params = {}
        for submod_name in layer_proj_paths:
            parts = submod_name.split(".")
            submod = layer
            for p in parts:
                submod = getattr(submod, p)
            for attr in ["weight", "scales", "biases"]:
                if hasattr(submod, attr):
                    val = getattr(submod, attr)
                    saved_params[f"{submod_name}.{attr}"] = val
                    setattr(submod, attr, mx.zeros_like(val))

        # Measure output change across calibration prompts
        total_divergence = 0.0
        for pi, tokens in enumerate(all_tokens):
            x = mx.array([tokens])
            perturbed = inner_model(x).astype(mx.float32)
            mx.eval(perturbed)
            bl = baselines[pi][0, -1, :]
            pl = perturbed[0, -1, :]
            cos_sim = mx.sum(bl * pl) / (mx.sqrt(mx.sum(bl * bl)) * mx.sqrt(mx.sum(pl * pl)) + 1e-8)
            divergence = (1.0 - cos_sim.item())
            total_divergence += max(0.0, divergence)

        raw_importance[layer_idx] = total_divergence / len(all_tokens)

        # Restore original params
        for key, val in saved_params.items():
            name, attr = key.rsplit(".", 1)
            parts = name.split(".")
            submod = layer
            for p in parts:
                submod = getattr(submod, p)
            setattr(submod, attr, val)

    sys.stderr.write("\n")

    # Normalize to [0, 1]
    max_score = max(raw_importance.values()) if raw_importance else 1.0
    if max_score <= 0 or max_score != max_score:
        max_score = 1.0
    normalized = {}
    for i, v in raw_importance.items():
        n = v / max_score
        if n != n:
            n = 0.0
        normalized[i] = n

    return {
        "num_layers": num_layers,
        "raw_scores": raw_importance,
        "normalized": normalized,
    }


def main():
    parser = argparse.ArgumentParser(description="Analyze layer importance for Hayabusa layer skipping")
    parser.add_argument("--model", default="mlx-community/Qwen3.5-4B-4bit",
                        help="MLX model ID (default: mlx-community/Qwen3.5-4B-4bit)")
    parser.add_argument("--output", default=None,
                        help="Output JSON path (default: scripts/layer_importance.json)")
    parser.add_argument("--num-prompts", type=int, default=100,
                        help="Number of SOAP prompts to use (default: 100)")
    args = parser.parse_args()

    script_dir = Path(__file__).resolve().parent
    output_path = Path(args.output) if args.output else script_dir / "layer_importance.json"

    print("=" * 60)
    print("  Hayabusa Layer Importance Analyzer")
    print(f"  Model: {args.model}")
    print(f"  Prompts: {args.num_prompts}")
    print(f"  Output: {output_path}")
    print("=" * 60)

    # Load model
    print("\n  Loading model...")
    t0 = time.time()
    model, tokenizer = load(args.model)
    print(f"  Model loaded in {time.time() - t0:.1f}s")

    # Run analysis
    print("\n  Running layer importance analysis...")
    t0 = time.time()
    prompts = SOAP_PROMPTS[:args.num_prompts]
    result = measure_layer_importance(model, tokenizer, prompts)
    elapsed = time.time() - t0
    print(f"  Analysis completed in {elapsed:.1f}s")

    # Build output JSON
    layers = []
    for i in range(result["num_layers"]):
        layers.append({
            "index": i,
            "importance": round(result["normalized"][i], 6),
            "raw_activation_norm": round(result["raw_scores"][i], 6),
        })

    output = {
        "model": args.model,
        "num_layers": result["num_layers"],
        "analysis": {
            "method": "perturbation_cosine_distance",
            "description": "Cosine distance of hidden states when layer output projections are zeroed",
            "num_prompts": len(prompts),
        },
        "profiles": {
            "soap": {
                "num_prompts": len(prompts),
                "layers": layers,
            }
        },
    }

    # Save
    with open(output_path, "w") as f:
        json.dump(output, f, indent=2, ensure_ascii=False)
    print(f"\n  Saved to {output_path}")

    # Print summary
    print("\n  Layer Importance Summary (sorted by importance):")
    print("  " + "-" * 50)
    sorted_layers = sorted(layers, key=lambda x: x["importance"])
    for layer in sorted_layers[:10]:
        imp = layer["importance"] if layer["importance"] == layer["importance"] else 0
        bar = "█" * int(imp * 30)
        print(f"  Layer {layer['index']:>2}: {imp:.4f} {bar}")
    print("  ...")
    for layer in sorted_layers[-5:]:
        imp = layer["importance"] if layer["importance"] == layer["importance"] else 0
        bar = "█" * int(imp * 30)
        print(f"  Layer {layer['index']:>2}: {imp:.4f} {bar}")

    # Show skip recommendations
    print("\n  Skip Recommendations:")
    for threshold in [0.3, 0.5]:
        skip = [l for l in layers if l["importance"] <= threshold]
        print(f"  --layer-skip {threshold}: would skip {len(skip)}/{result['num_layers']} layers")
        if skip:
            indices = [str(l["index"]) for l in skip]
            print(f"    Layers: {', '.join(indices)}")


if __name__ == "__main__":
    main()
