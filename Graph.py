import pandas as pd

if not hasattr(pd, 'Int64Index'):
    pd.Int64Index = pd.Index
if not hasattr(pd, 'Float64Index'):
    pd.Float64Index = pd.Index
if not hasattr(pd, 'UInt64Index'):
    pd.UInt64Index = pd.Index
import shap
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
import numpy as np
np.bool = bool
np.int = int


def shap_plots(model, X_test, feature_names, target_names, model_name):
    #this block is here to stop it from graphing just so testing is easier
    print("graphing has been temporarily disabled to make testing a little easier")
    return
    X_test_array = X_test.values if hasattr(X_test, 'values') else X_test
    feature_names = np.array(feature_names)
    
    print(f"\nGenerating SHAP plots for: {model_name}")
    
    try:
        explainer = shap.TreeExplainer(model)
    except Exception:
        explainer = shap.KernelExplainer(model.predict_proba,
                                         shap.sample(X_test_array, 100))
    
    shap_values = explainer.shap_values(X_test_array)
    
    if isinstance(shap_values, list):
        shap_values = np.stack(shap_values, axis=2)
    elif shap_values.ndim == 2:
        shap_values = shap_values[:, :, np.newaxis]
    
    n_outputs = shap_values.shape[2]

    for i, target in enumerate(target_names):
        # Binary classification: CatBoost returns shape (n_samples, n_features, 1)
        # Both classes share the same SHAP values (positive class)
        idx = min(i, n_outputs - 1)
        sv = shap_values[:, :, idx]
    
        mean_abs_shap = np.abs(sv).mean(axis=0)
        top_idx = np.argsort(mean_abs_shap)[-10:]

        plot_bar(sv, feature_names, top_idx, target, model_name)
        plot_violin(sv, X_test_array, feature_names, top_idx, target, model_name)
        plot_tornado(sv, feature_names, target, model_name)


def plot_bar(sv, feature_names, top_idx, target, model_name):
    mean_abs_shap = np.abs(sv).mean(axis=0)

    fig, ax = plt.subplots(figsize=(8, 9))
    ax.barh(feature_names[top_idx], mean_abs_shap[top_idx],
            color='steelblue')

    ax.set_xlabel("Mean |SHAP Value|")
    ax.set_title(f"{model_name} SHAP Importance — {target}")

    plt.tight_layout()
    filename = f"{model_name}_shap_bar_{target}.png"
    plt.savefig(filename, dpi=150)
    plt.close(fig)

    print(f"  Saved: {filename}")

def plot_violin(sv, X_test_array, feature_names, top_idx, target, model_name):
    fig, ax = plt.subplots(figsize=(9, 7))

    for plot_pos, j in enumerate(top_idx):
        shap_vals = sv[:, j]
        feature_vals = X_test_array[:, j]

        median_val = np.median(feature_vals)
        high_mask = feature_vals >= median_val
        low_mask = ~high_mask

        # HIGH values
        high_data = shap_vals[high_mask]
        if len(high_data) > 1:
            parts = ax.violinplot(high_data,
                                  positions=[plot_pos],
                                  vert=False,
                                  widths=0.6)
            for pc in parts['bodies']:
                pc.set_facecolor('#E74C3C')
                pc.set_alpha(0.6)

        # LOW values
        low_data = shap_vals[low_mask]
        if len(low_data) > 1:
            parts = ax.violinplot(low_data,
                                  positions=[plot_pos],
                                  vert=False,
                                  widths=0.6)
            for pc in parts['bodies']:
                pc.set_facecolor('#2E86AB')
                pc.set_alpha(0.6)

    ax.set_yticks(range(len(top_idx)))
    ax.set_yticklabels(feature_names[top_idx])
    ax.axvline(0, color='black', linestyle='--')

    ax.set_xlabel("SHAP Value")
    ax.set_title(f"{model_name} SHAP Violin — {target}")

    high_patch = mpatches.Patch(color='#E74C3C', alpha=0.6,
                                label='High feature value')
    low_patch = mpatches.Patch(color='#2E86AB', alpha=0.6,
                               label='Low feature value')

    ax.legend(handles=[high_patch, low_patch])

    plt.tight_layout()
    filename = f"{model_name}_shap_violin_{target}.png"
    plt.savefig(filename, dpi=150)
    plt.close(fig)

    print(f"  Saved: {filename}")

def plot_tornado(sv, feature_names, target, model_name):
    mean_pos = np.where(sv > 0, sv, 0).mean(axis=0)
    mean_neg = np.where(sv < 0, sv, 0).mean(axis=0)

    total_spread = mean_pos - mean_neg
    top_idx = np.argsort(total_spread)[-10:]

    fig, ax = plt.subplots(figsize=(9, 7))
    y_pos = np.arange(len(top_idx))

    ax.barh(y_pos, mean_pos[top_idx],
            color='#E74C3C', label='Pushes toward')
    ax.barh(y_pos, mean_neg[top_idx],
            color='#2E86AB', label='Pushes away')

    ax.set_yticks(y_pos)
    ax.set_yticklabels(feature_names[top_idx])
    ax.axvline(0, color='black')

    ax.set_xlabel("Mean SHAP Value")
    ax.set_title(f"{model_name} Tornado Plot — {target}")

    ax.legend()

    plt.tight_layout()
    filename = f"{model_name}_shap_tornado_{target}.png"
    plt.savefig(filename, dpi=150)
    plt.close(fig)

    print(f"  Saved: {filename}")
