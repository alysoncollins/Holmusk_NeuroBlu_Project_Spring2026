import shap
import matplotlib.pyplot as plt
import numpy as np
np.bool = bool #fix for mismatched numpy and shap version

def shap_plots(rf_model, X_test, feature_names, target_names, model):

    X_test_array = X_test.values if hasattr(X_test, 'values') else X_test

    for i, estimator in enumerate(rf_model.estimators_):
        target = target_names[i]
        print(f"\nGenerating SHAP plots for: {target}")

        explainer   = shap.Explainer(estimator)
        shap_values = explainer.shap_values(X_test_array)  # shape: (n_samples, n_features)

        # --- Bar plot: mean absolute SHAP per feature ---
        mean_abs_shap = np.abs(shap_values).mean(axis=0)
        sorted_idx    = np.argsort(mean_abs_shap)

        fig, ax = plt.subplots(figsize=(8, 9))
        ax.barh(
            [feature_names[j] for j in sorted_idx],
            mean_abs_shap[sorted_idx],
            color='steelblue'
        )
        ax.set_xlabel("Mean |SHAP Value|")
        ax.set_title(f"{model}_SHAP Importance — {target}")
        plt.tight_layout()
        plt.savefig(f"{model}_shap_bar_{target}.png", dpi=150)
        plt.close(fig)

        # --- Beeswarm: manual scatter per feature ---
        fig, ax = plt.subplots(figsize=(8, 9))
        for j in sorted_idx:
            feature_vals = X_test_array[:, j]
            shap_vals    = shap_values[:, j]

            # Normalize feature values to [0,1] for coloring
            vmin, vmax = feature_vals.min(), feature_vals.max()
            norm_vals  = (feature_vals - vmin) / (vmax - vmin + 1e-9)

            ax.scatter(
                shap_vals,
                np.full_like(shap_vals, j),
                c=norm_vals,
                cmap='coolwarm',
                alpha=0.5,
                s=15
            )

        ax.set_yticks(range(len(feature_names)))
        ax.set_yticklabels([feature_names[j] for j in sorted_idx])
        ax.axvline(0, color='black', linewidth=0.8, linestyle='--')
        ax.set_xlabel("SHAP Value")
        ax.set_title(f"{model}_SHAP Beeswarm — {target}")

        sm = plt.cm.ScalarMappable(cmap='coolwarm', norm=plt.Normalize(0, 1))
        sm.set_array([])
        plt.colorbar(sm, ax=ax, label="Feature Value (normalized)")

        plt.tight_layout()
        plt.savefig(f"{model}_shap_beeswarm_{target}.png", dpi=150)
        plt.close(fig)

        print(f"  Saved: {model}_shap_beeswarm_{target}.png")
        print(f"  Saved: {model}_shap_bar_{target}.png")