import pandas as pd

# patch to fix pandas and xgboost compatability
if not hasattr(pd, 'Int64Index'):
    pd.Int64Index = pd.Index
if not hasattr(pd, 'Float64Index'):
    pd.Float64Index = pd.Index
if not hasattr(pd, 'UInt64Index'):
    pd.UInt64Index = pd.Index
import shap
import matplotlib.pyplot as plt
import numpy as np

np.bool = bool  # fix for mismatched numpy and shap version
np.int = int


def shap_plots(model, X_test, feature_names, target_names, model_name):
    X_test_array = X_test.values if hasattr(X_test, 'values') else X_test
    feature_names = np.array(feature_names)

    print(f"\nGenerating SHAP plots for: {model_name}")

    try:
        explainer = shap.TreeExplainer(model)
    except Exception:
        explainer = shap.KernelExplainer(model.predict_proba, shap.sample(X_test_array, 100))

    shap_values = explainer.shap_values(X_test_array)

    # For multiclass, shap_values is (n_samples, n_features, n_classes)
    # For binary, it may be 2D — normalize to 3D either way
    if isinstance(shap_values, list):
        shap_values = np.stack(shap_values, axis=2)  # list of (n_samples, n_features) → 3D
    elif shap_values.ndim == 2:
        shap_values = shap_values[:, :, np.newaxis]

    for i, target in enumerate(target_names):
        sv = shap_values[:, :, i]  # (n_samples, n_features) for this class

        mean_abs_shap = np.abs(sv).mean(axis=0)
        sorted_idx = np.argsort(mean_abs_shap)
        top_idx = sorted_idx[-10:]

        # --- Bar plot ---

        fig, ax = plt.subplots(figsize=(8, 9))
        ax.barh(
            feature_names[top_idx],
            mean_abs_shap[top_idx],
            color='steelblue'
        )
        ax.set_xlabel("Mean |SHAP Value|")
        ax.set_title(f"{model_name} SHAP Importance — {target}")
        plt.tight_layout()
        plt.savefig(f"{model_name}_shap_bar_{target}.png", dpi=150)
        plt.close(fig)
        print(f"  Saved: {model_name}_shap_bar_{target}.png")

        # --- Beeswarm ---
        n_top = len(top_idx)
        fig, ax = plt.subplots(figsize=(8, max(4, n_top * 0.5)))  # dynamic height
        for plot_pos, j in enumerate(top_idx):  # plot_pos = 0-9, j = original feature index
            feature_vals = X_test_array[:, j]
            shap_vals = sv[:, j]
            vmin, vmax = feature_vals.min(), feature_vals.max()
            norm_vals = (feature_vals - vmin) / (vmax - vmin + 1e-9)
            ax.scatter(
                shap_vals,
                np.full_like(shap_vals, plot_pos),  # use plot_pos not j
                c=norm_vals,
                cmap='coolwarm',
                alpha=0.5,
                s=15
            )
        ax.set_yticks(range(n_top))
        ax.set_yticklabels(feature_names[top_idx])  # already in ascending order
        ax.set_ylim(-0.5, n_top - 0.5)  # tight fit around the 10 rows
        ax.axvline(0, color='black', linewidth=0.8, linestyle='--')
        ax.set_xlabel("SHAP Value")
        ax.set_title(f"{model_name} SHAP Beeswarm — {target}")
        sm = plt.cm.ScalarMappable(cmap='coolwarm', norm=plt.Normalize(0, 1))
        sm.set_array([])
        plt.colorbar(sm, ax=ax, label="Feature Value (normalized)")
        plt.tight_layout()
        plt.savefig(f"{model_name}_shap_beeswarm_{target}.png", dpi=150)
        plt.close(fig)
        print(f"  Saved: {model_name}_shap_beeswarm_{target}.png")